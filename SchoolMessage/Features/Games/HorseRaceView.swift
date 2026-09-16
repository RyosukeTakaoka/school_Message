import Foundation
import SwiftUI

/// 競馬の画面.
///
/// ## 走りと着順がずれない理由
/// 馬の位置は `HorseRaceRun.position(of:at:)` の値をそのまま使っている.
/// 着順もまったく同じ計算のゴール順なので, 見えている走りと結果が
/// 食い違うことはない(`HorseRace.swift` のコメント参照).
///
/// 演出は `TimelineView` で実時間から進み具合を出して, 毎フレーム位置を
/// 計算し直している. SwiftUI の `withAnimation` に任せると, 始点と終点の間を
/// まっすぐ補間されてしまい, 脚質ごとの走りの形(逃げ・追込)が消えるため.
struct HorseRaceView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var state: HorseRaceState?
    @State private var isLoading = false
    @State private var isPlacingBet = false

    /// レースの演出を始めた時刻. nil なら演出していない(結果だけ表示).
    @State private var runStartedAt: Date?

    @State private var betKind: HorseRaceBetKind = .win
    @State private var selections: [Int] = []
    @State private var amount = ChipRules.minBet

    private var store: ChatStore { environment.store }

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    content(state)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("競馬")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
        }
    }

    // MARK: - 全体

    private func content(_ state: HorseRaceState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                header(state)

                if let run = state.run {
                    raceTrack(run)
                    resultSection(state, run: run)
                }

                if state.isResultUntrusted {
                    untrustedNotice
                }

                entriesSection(state)

                if case .betting = state.phase {
                    Divider()
                    bettingSection(state)
                }

                if !state.myBets.isEmpty {
                    Divider()
                    myBetsSection(state)
                }
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    private func header(_ state: HorseRaceState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayText(state.raceID))
                    .font(.headline)
                Spacer()
                ChipBalanceBadge(compact: true)
            }
            Text(phaseText(state.phase))
                .font(.subheadline)
                .foregroundStyle(Palette.subdued)
            Text("発走 \(postTimeText) / 締切 \(closingTimeText) ・ 馬券 \(state.totalBetCount) 枚")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
        }
    }

    private var postTimeText: String {
        String(format: "%02d:%02d", HorseRaceRules.postHour, HorseRaceRules.postMinute)
    }

    private var closingTimeText: String {
        String(format: "%02d:%02d", HorseRaceRules.closingHour, HorseRaceRules.closingMinute)
    }

    private var untrustedNotice: some View {
        Text("このレースの結果は確認できませんでした。払い戻しは行いません。")
            .font(.footnote)
            .foregroundStyle(Palette.failure)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - レースの演出

    private func raceTrack(_ run: HorseRaceRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("レース")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Spacer()
                Button(String(localized: "もう一度見る")) {
                    runStartedAt = .now
                }
                .font(.caption.weight(.semibold))
            }

            TimelineView(.animation) { context in
                track(run, progress: progress(at: context.date))
            }
            .frame(height: CGFloat(run.card.horses.count) * 32)
        }
    }

    /// 演出の進み具合(0〜1). 始めていなければ 1(＝ゴールした状態)を返す.
    private func progress(at date: Date) -> Double {
        guard let runStartedAt else { return 1 }
        let elapsed = date.timeIntervalSince(runStartedAt)
        return min(max(elapsed / HorseRaceRules.runDuration, 0), 1)
    }

    private func track(_ run: HorseRaceRun, progress: Double) -> some View {
        GeometryReader { geometry in
            let laneWidth = max(geometry.size.width - 34, 0)
            let travel = max(laneWidth - 30, 0)

            VStack(spacing: 4) {
                ForEach(run.card.horses) { horse in
                    HStack(spacing: 6) {
                        numberBadge(horse.number)

                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.incomingBubble)
                                .frame(height: 24)

                            // ゴール板.
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 2, height: 24)
                                .offset(x: travel + 26)

                            Text("🐎")
                                .font(.system(size: 20))
                                // 絵文字は左を向いているので, 進む向きに合わせて反転する.
                                .scaleEffect(x: -1, y: 1)
                                .offset(x: travel * run.position(of: horse.number, at: progress))
                        }
                    }
                    .frame(height: 28)
                }
            }
        }
    }

    private func numberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(horseColor(number), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: - 結果

    private func resultSection(_ state: HorseRaceState, run: HorseRaceRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("結果")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            ForEach(Array(run.topThree.enumerated()), id: \.offset) { index, number in
                HStack(spacing: 8) {
                    Text(placeLabel(index + 1))
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, alignment: .leading)
                    numberBadge(number)
                    Text(run.card.horse(number: number)?.name ?? "")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
            }

            if let payout = state.payout, !state.myBets.isEmpty {
                ChipResultBanner(delta: payout - state.myTotalStake)
                    .padding(.top, 4)
            }
        }
    }

    private func placeLabel(_ place: Int) -> String {
        switch place {
        case 1: String(localized: "1着")
        case 2: String(localized: "2着")
        default: String(localized: "3着")
        }
    }

    // MARK: - 出走表

    private func entriesSection(_ state: HorseRaceState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出走表")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            ForEach(state.card.horses) { horse in
                HStack(spacing: 8) {
                    numberBadge(horse.number)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(horse.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(horse.style.title)・調子 \(horse.condition.mark)・近走 \(horse.recentFormText)")
                            .font(.caption2)
                            .foregroundStyle(Palette.subdued)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.1f倍", state.card.winOdds(of: horse.number)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text("\(state.card.popularity(of: horse.number))番人気")
                            .font(.caption2)
                            .foregroundStyle(Palette.subdued)
                    }

                    if let rank = state.run?.rank(of: horse.number) {
                        Text("\(rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(rank <= 3 ? Color.accentColor : Palette.subdued)
                            .frame(width: 20)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 馬券を買う

    private func bettingSection(_ state: HorseRaceState) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
            Text("馬券を買う")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            kindPicker

            Text(betKind.detail)
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            selectionGrid(state)

            if !selections.isEmpty {
                Text(selectionSummary)
                    .font(.subheadline)
            }

            if selections.count == betKind.selectionCount {
                let odds = state.card.odds(kind: betKind, selections: selections)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "オッズ %.1f倍 ・ 的中なら %d CHIP", odds, Int((Double(amount) * odds).rounded(.down))))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    // 当たりにくい買い目は, 本来のオッズが上限を超えている.
                    // 黙って頭を抑えると損をした気分になるので明示する.
                    if odds >= HorseRaceRules.maxOdds {
                        Text("オッズは\(Int(HorseRaceRules.maxOdds))倍が上限です")
                            .font(.caption2)
                            .foregroundStyle(Palette.subdued)
                    }
                }
            }

            ChipBetPicker(maxBet: HorseRaceRules.maxBet, bet: $amount)

            Button {
                Task { await buy(state) }
            } label: {
                Text("この買い目で購入")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPlacingBet || selections.count != betKind.selectionCount)
        }
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HorseRaceBetKind.allCases) { kind in
                    Button {
                        betKind = kind
                        selections = []
                    } label: {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                betKind == kind ? Color.accentColor : Palette.incomingBubble,
                                in: Capsule()
                            )
                            .foregroundStyle(betKind == kind ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 馬を選ぶ. 順番に意味がある券種では, 選んだ順がそのまま着順の指定になる.
    private func selectionGrid(_ state: HorseRaceState) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
            ForEach(state.card.horses) { horse in
                Button {
                    toggle(horse.number)
                } label: {
                    VStack(spacing: 1) {
                        Text("\(horse.number)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                        if let index = selections.firstIndex(of: horse.number), betKind.isOrdered {
                            Text(placeLabel(index + 1))
                                .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selections.contains(horse.number) ? horseColor(horse.number) : Palette.incomingBubble,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .foregroundStyle(selections.contains(horse.number) ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectionSummary: String {
        let text = betKind.isOrdered
            ? selections.map(String.init).joined(separator: " → ")
            : selections.sorted().map(String.init).joined(separator: "・")
        return "\(betKind.title) \(text)"
    }

    private func toggle(_ number: Int) {
        if let index = selections.firstIndex(of: number) {
            selections.remove(at: index)
            return
        }
        guard selections.count < betKind.selectionCount else { return }
        selections.append(number)
    }

    // MARK: - 自分の馬券

    private func myBetsSection(_ state: HorseRaceState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("自分の馬券")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            ForEach(state.myBets) { bet in
                HStack(spacing: 8) {
                    Text(bet.kind.title)
                        .font(.caption.weight(.semibold))
                        .frame(width: 52, alignment: .leading)
                    Text(bet.selectionsText)
                        .font(.subheadline.monospacedDigit())
                    Spacer(minLength: 0)
                    Text(ChipRules.formatted(bet.amount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.subdued)
                    if let run = state.run {
                        let payout = run.payout(for: bet)
                        Text(payout > 0 ? "的中 +\(payout)" : "外れ")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(payout > 0 ? .green : Palette.subdued)
                    }
                }
            }
        }
    }

    // MARK: - 動作

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await store.refreshWallet()
        let raceID = HorseRaceSchedule.currentRaceID()
        let loaded = await store.loadHorseRace(raceID: raceID)

        // 結果が出たところを初めて見たときだけ, 走りを最初から見せる.
        let isNewResult = loaded.run != nil && state?.run == nil
        state = loaded
        if isNewResult { runStartedAt = .now }
    }

    private func buy(_ state: HorseRaceState) async {
        guard !isPlacingBet else { return }
        isPlacingBet = true
        defer { isPlacingBet = false }

        let placed = await store.placeHorseRaceBet(
            raceID: state.raceID,
            kind: betKind,
            selections: selections,
            amount: amount
        )
        guard placed else { return }
        selections = []
        await load()
    }

    // MARK: - 表示のこまごま

    private func dayText(_ raceID: String) -> String {
        guard let date = HorseRaceSchedule.date(fromRaceID: raceID) else { return raceID }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MdEEE")
        return String(localized: "\(formatter.string(from: date)) のレース")
    }

    private func phaseText(_ phase: HorseRaceSchedule.Phase) -> String {
        switch phase {
        case .betting(let closesAt):
            String(localized: "受付中(\(timeText(closesAt)) 締切)")
        case .closed(let startsAt):
            String(localized: "締切りました。\(timeText(startsAt)) に発走します")
        case .finished:
            String(localized: "確定しました")
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter.string(from: date)
    }

    private func horseColor(_ number: Int) -> Color {
        let palette: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]
        return palette[(number - 1) % palette.count]
    }
}

#Preview {
    HorseRaceView()
        .environment(AppEnvironment.preview())
}
