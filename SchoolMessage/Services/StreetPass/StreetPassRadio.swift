import CoreBluetooth
import Foundation

/// すれ違い通信の無線部分.
///
/// ## 端末は発信側と受信側の両方になる
/// - 発信側(`CBPeripheralManager`): 決まったサービス UUID を広告し,
///   「名刺を読み出す特性」と「名刺を書き込む特性」を用意する
/// - 受信側(`CBCentralManager`): 同じ UUID を探し, 見つけたら接続して
///   相手の名刺を**読み**, 続けて自分の名刺を**書き**, すぐ切る
///
/// ## なぜ読むだけでなく書き込むのか
/// すれ違いは本来ひとつの出来事なのに, 電波の上では A→B と B→A の
/// 2 本の独立した試行になる. 読むだけだと, A の走査が当たっても B の走査が
/// 当たらなかった場合, A にしか記録が残らない. 背面同士では走査が大きく
/// 間引かれるので, これは頻繁に起きる.
///
/// つないだついでに自分の名刺を置いていけば, **1 本つながった時点で双方に
/// 記録が残る**. 背面での取りこぼしが目に見えて減る, いちばん効く工夫.
///
/// ## なぜ広告そのものに名刺を載せないのか
/// iOS はアプリが背面に回ると, 広告パケットから独自のデータを落とす.
/// 残るのはサービス UUID だけで, それも「その UUID を明示的に探している
/// iOS 端末」からしか見えない(オーバーフロー領域). そのため,
/// 見つけた後に一度つないで交換する. 背面同士でも成立する唯一の形.
///
/// ## 復元(State Restoration)
/// システムに落とされた後でも, `CBCentralManagerOptionRestoreIdentifierKey` を
/// 付けておけば, 近くに相手が現れた時点で iOS がアプリを起こし直してくれる.
/// ただし条件があり, **起動のごく早い段階でマネージャを作り直していること**.
/// そのためこの部品は画面(SwiftUI)ではなく `StreetPassKit` が持ち,
/// `AppDelegate.application(_:willFinishLaunchingWithOptions:)` で組み立てる.
///
/// CoreBluetooth の通知はメインスレッドで受け取る(`queue: nil`). 呼び出し側も
/// メインスレッドからしか触らないので, その前提で `@unchecked Sendable` にしている.
final class StreetPassRadio: NSObject, @unchecked Sendable {

    // MARK: - 決め打ちの値

    /// このアプリのすれ違い用サービス. 他のアプリと衝突しない固定値.
    static let serviceUUID = CBUUID(string: "A7F3C1D0-5E8B-4C2A-9F16-3B7D9E4A6C81")
    /// 相手の名刺を読み出す特性.
    static let cardCharacteristicUUID = CBUUID(string: "A7F3C1D1-5E8B-4C2A-9F16-3B7D9E4A6C81")
    /// 自分の名刺を置いていく特性.
    static let dropCharacteristicUUID = CBUUID(string: "A7F3C1D2-5E8B-4C2A-9F16-3B7D9E4A6C81")

    /// 復元のための名札. 変えると復元が切れるので固定する.
    private static let centralRestoreIdentifier = "schoolmessage.streetpass.central"
    private static let peripheralRestoreIdentifier = "schoolmessage.streetpass.peripheral"

    /// 交換に成功した相手を, 次に読みにいくまでの間隔.
    /// 一緒にいる間ずっと接続を繰り返して電池を食うのを防ぐ.
    private static let successCooldown: TimeInterval = 180

    /// 失敗した相手を待つ最初の時間. 以降は倍々にしていく.
    private static let failureBackoffBase: TimeInterval = 20
    private static let failureBackoffMax: TimeInterval = 600

    /// つながらないまま抱え込まないための打ち切り時間.
    /// 通常の交換は数秒で終わる. これは異常時の保険.
    private static let exchangeTimeout: TimeInterval = 15

    /// 走査の仕切り直しをまとめる待ち時間.
    private static let rescanDebounce: TimeInterval = 2

    /// 書き込みで受け取る名刺の上限. これを超える相手は相手にしない.
    private static let maxInboundBytes = 1024

    // MARK: - 状態

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

    /// 相手ごとの待ち時間. 一度失敗しても, 次のすれ違いでまた試す.
    private struct PeerState {
        var nextAttempt: Date = .distantPast
        var failureCount = 0
    }

    private let onEncounter: (StreetPassCard, Int?) -> Void
    private let onStatusChange: (Status) -> Void
    private let onRestore: () -> Void

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    /// 配る名刺(JSON).
    private var cardData: Data?
    private var isServiceAdded = false

    /// 接続中の相手.
    /// `CBPeripheral` は強い参照を持っていないと解放され, 接続が途中で切れる.
    private var connecting: [UUID: CBPeripheral] = [:]
    /// 交換のあいだ覚えておく電波の強さ.
    private var discoveredRSSI: [UUID: Int] = [:]
    private var peers: [UUID: PeerState] = [:]
    /// 書き込みで届いた名刺の組み立て途中.
    private var inbound: [UUID: Data] = [:]
    /// 走査の仕切り直しを予約済みか.
    private var isRescanScheduled = false

    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChange(status)
        }
    }

    init(
        onEncounter: @escaping (StreetPassCard, Int?) -> Void,
        onStatusChange: @escaping (Status) -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.onEncounter = onEncounter
        self.onStatusChange = onStatusChange
        self.onRestore = onRestore
        super.init()
    }

    // MARK: - 開始 / 停止

    /// 配る名刺を差し替える.
    func updateCard(_ data: Data?) {
        cardData = data
    }

    func start() {
        guard central == nil, peripheralManager == nil else { return }
        // queue に nil を渡すとメインキューで通知される.
        // RestoreIdentifier を付けることで, システムに落とされた後も
        // 相手が現れた時点で iOS がアプリを起こし直してくれる.
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreIdentifier]
        )
    }

    func stop() {
        for peripheral in connecting.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        connecting.removeAll()
        inbound.removeAll()
        discoveredRSSI.removeAll()

        central?.stopScan()
        central = nil

        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager = nil
        isServiceAdded = false

        status = .idle
    }

    /// 前面に戻ったときなどに, 近くにいる相手を拾い直す.
    func rescan() {
        restartScan()
    }

    // MARK: - 走査
    //
    // 走査は「同じ端末を何度も報告しない」設定で動かす(電池のため).
    // その代わり, 交換が一区切りついた時点で仕切り直して, 次のすれ違いを
    // 拾えるようにする. 時計で定期的に叩くやり方は, 背面では止まってしまう
    // (アプリが眠っているあいだタイマは進まない)ので, 出来事で駆動する.

    private func startScan() {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func restartScan() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        startScan()
    }

    /// 交換のたびに叩かれるので, 少しまとめてから仕切り直す.
    private func scheduleRescan() {
        guard !isRescanScheduled else { return }
        isRescanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescanDebounce) { [weak self] in
            guard let self else { return }
            self.isRescanScheduled = false
            self.restartScan()
        }
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

    // MARK: - 相手ごとの待ち時間

    private func mayApproach(_ id: UUID) -> Bool {
        guard let state = peers[id] else { return true }
        return state.nextAttempt <= .now
    }

    private func noteSuccess(_ id: UUID) {
        peers[id] = PeerState(nextAttempt: .now.addingTimeInterval(Self.successCooldown), failureCount: 0)
    }

    private func noteFailure(_ id: UUID) {
        var state = peers[id] ?? PeerState()
        state.failureCount += 1
        let delay = min(
            Self.failureBackoffBase * pow(2, Double(state.failureCount - 1)),
            Self.failureBackoffMax
        )
        state.nextAttempt = .now.addingTimeInterval(delay)
        peers[id] = state
    }

    /// 交換を終える. 成否にかかわらず接続を解いて, 次のすれ違いに備える.
    private func finish(_ peripheral: CBPeripheral, succeeded: Bool) {
        let id = peripheral.identifier
        guard connecting[id] != nil else { return }

        if succeeded { noteSuccess(id) } else { noteFailure(id) }
        central?.cancelPeripheralConnection(peripheral)
        connecting[id] = nil
        discoveredRSSI[id] = nil
        scheduleRescan()
    }
}

// MARK: - 受信側(見つけて, 読んで, 置いていく)

extension StreetPassRadio: CBCentralManagerDelegate {

    /// システムに落とされた後の復帰. `centralManagerDidUpdateState` より先に呼ばれる.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // init から戻る前に呼ばれることがあるため, ここで受け取っておく.
        self.central = central
        onRestore()

        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripheral.delegate = self
            connecting[peripheral.identifier] = peripheral
        }
        Log.streetPass.info("restored \(restored.count, privacy: .public) peripheral(s)")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.central = central
        updateStatusFromManagers()
        guard central.state == .poweredOn else { return }

        // 復元でつながったままの相手がいれば, 途中から続ける.
        for peripheral in connecting.values where peripheral.state == .connected {
            peripheral.discoverServices([Self.serviceUUID])
        }
        startScan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        guard mayApproach(id), connecting[id] == nil else { return }

        // RSSI は記録には残すが, 判定には使わない.
        // 体や壁で簡単に 20dBm 以上変わるので, 足切りすると本当のすれ違いを落とす.
        discoveredRSSI[id] = RSSI.intValue
        connecting[id] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        // つながらないまま残ると, その相手を抱えたままになる.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exchangeTimeout) { [weak self] in
            guard let self, let stuck = self.connecting[id] else { return }
            Log.streetPass.notice("exchange timed out")
            self.finish(stuck, succeeded: false)
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
        finish(peripheral, succeeded: false)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let id = peripheral.identifier
        guard connecting[id] != nil else { return }
        // 交換の途中で切れた場合. 成功していれば finish 済みなのでここには来ない.
        noteFailure(id)
        connecting[id] = nil
        discoveredRSSI[id] = nil
        scheduleRescan()
    }
}

extension StreetPassRadio: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finish(peripheral, succeeded: false)
            return
        }
        peripheral.discoverCharacteristics(
            [Self.cardCharacteristicUUID, Self.dropCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard error == nil,
              let card = service.characteristics?.first(where: { $0.uuid == Self.cardCharacteristicUUID }) else {
            finish(peripheral, succeeded: false)
            return
        }
        peripheral.readValue(for: card)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if error == nil,
           let value = characteristic.value,
           let card = StreetPassCard.decoded(from: value) {
            Log.streetPass.info("read a card over bluetooth")
            onEncounter(card, discoveredRSSI[peripheral.identifier])
        }

        // 読めても読めなくても, 自分の名刺は置いていく.
        // 相手の走査がこちらを見つけられなくても, これで相手にも記録が残る.
        drop(to: peripheral)
    }

    private func drop(to peripheral: CBPeripheral) {
        guard let cardData,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }),
              let drop = service.characteristics?.first(where: { $0.uuid == Self.dropCharacteristicUUID }) else {
            finish(peripheral, succeeded: true)
            return
        }
        // 応答ありで書く. 名刺が MTU を超えても CoreBluetooth が分割してくれる.
        peripheral.writeValue(cardData, for: drop, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            Log.streetPass.notice("could not drop a card: \(error.localizedDescription, privacy: .public)")
        }
        // 読めた時点ですれ違いは成立している. 書き込みの失敗では待たせない.
        finish(peripheral, succeeded: true)
    }
}

// MARK: - 発信側(広告し, 読ませ, 置かれた名刺を受け取る)

extension StreetPassRadio: CBPeripheralManagerDelegate {

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        self.peripheralManager = peripheral

        // 復元されたときはサービスも一緒に戻ってくる. 二重に add しない.
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        if services.contains(where: { $0.uuid == Self.serviceUUID }) {
            isServiceAdded = true
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        self.peripheralManager = peripheral
        updateStatusFromManagers()
        guard peripheral.state == .poweredOn else { return }

        if isServiceAdded {
            // 復元された場合. 広告だけ入れ直す.
            if !peripheral.isAdvertising { startAdvertising(on: peripheral) }
            return
        }

        let card = CBMutableCharacteristic(
            type: Self.cardCharacteristicUUID,
            properties: [.read],
            value: nil,          // 読み出しのたびに最新の名刺を返すため, 固定値にしない
            permissions: [.readable]
        )
        let drop = CBMutableCharacteristic(
            type: Self.dropCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [card, drop]
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
        startAdvertising(on: peripheral)
    }

    private func startAdvertising(on peripheral: CBPeripheralManager) {
        // 背面では名前などは落とされ, サービス UUID だけが残る.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    /// 相手がこちらの名刺を読みにきた.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.cardCharacteristicUUID, let cardData else {
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

    /// 相手が自分の名刺を置いていった.
    ///
    /// こちらの走査が相手を見つけられなくても, この経路で記録が残る.
    /// 名刺が MTU を超えると複数の要求に分かれて届くので, 位置を見て組み立てる.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard first.characteristic.uuid == Self.dropCharacteristicUUID else {
            peripheral.respond(to: first, withResult: .attributeNotFound)
            return
        }

        let key = first.central.identifier
        var buffer = inbound[key] ?? Data()

        for request in requests {
            guard let value = request.value else { continue }
            let end = request.offset + value.count
            guard end <= Self.maxInboundBytes else {
                inbound[key] = nil
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                return
            }
            if buffer.count < end {
                buffer.append(Data(count: end - buffer.count))
            }
            buffer.replaceSubrange(request.offset..<end, with: value)
        }

        // 応答は最初の 1 件に対してだけ返す(CoreBluetooth の決まり).
        peripheral.respond(to: first, withResult: .success)

        if let card = StreetPassCard.decoded(from: buffer) {
            inbound[key] = nil
            Log.streetPass.info("received a dropped card over bluetooth")
            // 書き込み経路では相手との距離が測れないので RSSI は残さない.
            onEncounter(card, nil)
        } else {
            inbound[key] = buffer
        }
    }
}
