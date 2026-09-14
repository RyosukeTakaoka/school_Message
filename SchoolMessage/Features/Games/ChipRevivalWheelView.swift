import SwiftUI

/// CHIP が 0 になったあとの「復活ルーレット」.
///
/// 回せるようになる(0 になった日の翌々日)と自動で出てくる. 出る額は
/// 0 になった時点で決まっていて, 開き直しても変わらない(回し直しはできない).
struct ChipRevivalWheelView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayAmount = PlayerWallet.initialBalance
    @State private var result: Int?
    @State private var spinTask: Task<Void, Never>?

    private var store: ChatStore { environment.store }

    /// 演出として最低これだけは回す.
    private static let minimumSpin = Duration.milliseconds(1800)

    var body: some View {
        NavigationStack {
            VStack(spacing: AppConstants.Layout.standardSpacing) {
                Spacer(minLength: 0)

                Text(result == nil ? String(localized: "回しています…") : ChipRevivalWheel.title(for: result ?? 0))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(result == nil ? Palette.subdued : Color.primary)

                amountPanel

                if let result {
                    Text(message(for: result))
                        .font(.footnote)
                        .foregroundStyle(Palette.subdued)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, AppConstants.Layout.standardSpacing)

                    Button(String(localized: "閉じる")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                }

                Spacer(minLength: 0)
                probabilityTable
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.chatBackground)
            .navigationTitle("復活ルーレット")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(result == nil)
        }
        .task { await spin() }
        .onDisappear { spinTask?.cancel() }
    }

    // MARK: - 部品

    private var amountPanel: some View {
        VStack(spacing: 4) {
            Text("🪙")
                .font(.largeTitle)
            Text(ChipRules.formatted(displayAmount))
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Palette.incomingBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(result == nil ? Color.clear : Color.accentColor, lineWidth: 3)
        }
        .padding(.horizontal, AppConstants.Layout.standardSpacing)
    }

    private var probabilityTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("出る割合")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ChipRevivalWheel.slots) { slot in
                        VStack(spacing: 2) {
                            Text("\(slot.amount)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                            Text("\(slot.weight)%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Palette.subdued)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            slot.amount == result ? Color.accentColor.opacity(0.2) : Palette.incomingBubble,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                }
            }
        }
        .padding(AppConstants.Layout.standardSpacing)
    }

    private func message(for amount: Int) -> String {
        if amount < ChipRules.minBet {
            return String(localized: "残念! 今回は 0 でした。もう一度待つと、また回せます。")
        }
        if amount >= PlayerWallet.initialBalance * 2 {
            return String(localized: "いちばん大きい当たりです。CHIPはアプリの中のゲームでしか使えません。")
        }
        return String(localized: "この CHIP でまた遊べます。")
    }

    // MARK: - 動作

    private func spin() async {
        spinTask = Task {
            while !Task.isCancelled {
                displayAmount = ChipRevivalWheel.slots.randomElement()?.amount ?? 0
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        // 受け取り自体はここで済ませてしまう(途中でアプリを閉じても結果は変わらない).
        async let claimed = store.claimRevivalIfDue()
        try? await Task.sleep(for: Self.minimumSpin)

        spinTask?.cancel()
        guard let amount = await claimed else {
            // 回せる状態ではなかった(すでに受け取り済みなど).
            dismiss()
            return
        }
        withAnimation(.snappy) {
            displayAmount = amount
            result = amount
        }
    }
}

#Preview {
    ChipRevivalWheelView()
        .environment(AppEnvironment.preview())
}
