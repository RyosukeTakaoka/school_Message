import CoreBluetooth
import Foundation

/// すれ違い通信の無線部分.
///
/// ## 仕組み
/// 端末は**発信側と受信側の両方**になる.
/// - 発信側(`CBPeripheralManager`): 決まったサービス UUID を広告し,
///   名刺を読み出せる特性を 1 つ用意する
/// - 受信側(`CBCentralManager`): 同じ UUID を探し, 見つけたら接続して
///   名刺を読み, すぐ切る
///
/// ## なぜ広告に名刺を載せないのか
/// iOS はアプリが背面に回ると, 広告パケットから独自のデータを落としてしまう
/// (残るのはサービス UUID だけで, それも「その UUID を明示的に探している
/// iOS 端末」からしか見えない). そのため, 見つけた後に一度つないで読む.
/// 広告に載せるより往復は増えるが, 背面同士でも成立する唯一の形.
///
/// ## 動く条件と限界(正直なところ)
/// - 前面に出ていれば数秒で見つかる
/// - 背面同士では iOS が大きく間引くので, 数十秒〜数分かかることがある
/// - **アプリを上スワイプで終了させると止まる**(iOS が起こしてくれない)
/// - 端末を再起動した場合も, 次にアプリを開くまで止まる
///
/// CoreBluetooth の通知はメインスレッドで受け取る(`queue: nil`). 呼び出し側も
/// メインスレッドからしか触らないので, その前提で `@unchecked Sendable` にしている.
final class StreetPassRadio: NSObject, @unchecked Sendable {

    /// このアプリのすれ違い用サービス. 他のアプリと衝突しない固定値.
    static let serviceUUID = CBUUID(string: "A7F3C1D0-5E8B-4C2A-9F16-3B7D9E4A6C81")
    /// 名刺を読み出す特性.
    static let cardCharacteristicUUID = CBUUID(string: "A7F3C1D1-5E8B-4C2A-9F16-3B7D9E4A6C81")

    /// 同じ端末から続けて読み込まない間隔.
    /// これが無いと, 同じ相手と一緒にいる間ずっと接続を繰り返して電池を食う.
    static let peerCooldown: TimeInterval = 180

    /// つながらないまま抱え込まないための打ち切り時間.
    private static let connectTimeout: TimeInterval = 15

    enum Status: Sendable, Equatable {
        /// 止めている.
        case idle
        /// この端末は Bluetooth LE に対応していない.
        case unsupported
        /// Bluetooth の使用が許可されていない.
        case unauthorized
        /// Bluetooth が切られている.
        case poweredOff
        /// 動いている.
        case running
    }

    private let onEncounter: @Sendable (StreetPassCard) -> Void
    private let onStatusChange: @Sendable (Status) -> Void

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    /// 広告する名刺(JSON). 読み出し要求にそのまま返す.
    private var cardData: Data?
    private var isServiceAdded = false

    /// 接続中の相手.
    /// `CBPeripheral` は強い参照を持っていないと解放され, 接続が途中で切れる.
    private var connecting: [UUID: CBPeripheral] = [:]
    /// 最後に読み終えた時刻. 連続接続を抑える.
    private var lastRead: [UUID: Date] = [:]

    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChange(status)
        }
    }

    init(
        onEncounter: @escaping @Sendable (StreetPassCard) -> Void,
        onStatusChange: @escaping @Sendable (Status) -> Void
    ) {
        self.onEncounter = onEncounter
        self.onStatusChange = onStatusChange
        super.init()
    }

    // MARK: - 開始 / 停止

    /// 名刺を差し替える. 開始前に一度は呼ぶこと.
    func updateCard(_ data: Data?) {
        cardData = data
    }

    func start() {
        guard central == nil, peripheralManager == nil else { return }
        // queue に nil を渡すとメインキューで通知される.
        central = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        for peripheral in connecting.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        connecting.removeAll()

        central?.stopScan()
        central = nil

        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager = nil
        isServiceAdded = false

        status = .idle
    }

    /// 探し直す.
    ///
    /// 走査は「同じ端末を何度も報告しない」設定で動かしているので, いったん
    /// 止めて始め直さないと, 近くにいる相手と再びすれ違ったことに気付けない.
    func rescan() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        startScan(on: central)
    }

    private func startScan(on central: CBCentralManager) {
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            // 重複報告を切ることで電池を守る. 再会は rescan() で拾う.
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func updateStatusFromManagers() {
        guard central != nil || peripheralManager != nil else {
            status = .idle
            return
        }
        switch central?.state ?? peripheralManager?.state ?? .unknown {
        case .unsupported: status = .unsupported
        case .unauthorized: status = .unauthorized
        case .poweredOff: status = .poweredOff
        case .poweredOn: status = .running
        default: break
        }
    }
}

// MARK: - 受信側

extension StreetPassRadio: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateStatusFromManagers()
        guard central.state == .poweredOn else { return }
        startScan(on: central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        if let last = lastRead[id], Date.now.timeIntervalSince(last) < Self.peerCooldown { return }
        guard connecting[id] == nil else { return }

        connecting[id] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        // つながらないまま残ると, その相手を二度と読みにいかなくなる.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, let stuck = self.connecting[id] else { return }
            self.central?.cancelPeripheralConnection(stuck)
            self.connecting[id] = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        connecting[peripheral.identifier] = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        connecting[peripheral.identifier] = nil
    }
}

extension StreetPassRadio: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finish(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.cardCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.cardCharacteristicUUID }) else {
            finish(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        defer { finish(peripheral) }
        guard error == nil,
              let value = characteristic.value,
              let card = StreetPassCard.decoded(from: value) else { return }

        lastRead[peripheral.identifier] = .now
        Log.streetPass.info("met a card over bluetooth")
        onEncounter(card)
    }

    private func finish(_ peripheral: CBPeripheral) {
        central?.cancelPeripheralConnection(peripheral)
        connecting[peripheral.identifier] = nil
    }
}

// MARK: - 発信側

extension StreetPassRadio: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        updateStatusFromManagers()
        guard peripheral.state == .poweredOn else { return }
        guard !isServiceAdded else { return }

        let characteristic = CBMutableCharacteristic(
            type: Self.cardCharacteristicUUID,
            properties: [.read],
            value: nil,          // 読み出しのたびに最新の名刺を返すため, 固定値にしない
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
        isServiceAdded = true
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: (any Error)?
    ) {
        guard error == nil else {
            Log.streetPass.error("could not publish the street pass service")
            isServiceAdded = false
            return
        }
        // 背面ではここに書いた名前などは落とされ, UUID だけが残る.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let cardData else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= cardData.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = cardData.subdata(in: request.offset..<cardData.count)
        peripheral.respond(to: request, withResult: .success)
    }
}
