import SwiftUI

/// 対戦できる遊びのルールをまとめて見られる画面.
///
/// 各ゲームの画面にもルール説明はあるが, 対戦を始める前(または誘われる前)に
/// 「どんな遊びがあるか」をまとめて確認したいという要望から, ランキング画面の
/// すぐ近くに一覧できる場所を用意した.
struct GameRulesView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(GameSnapshot.Kind.allCases) { kind in
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(kind.rules)
                                .font(.footnote)
                                .foregroundStyle(Palette.subdued)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Label(kind.title, systemImage: kind.symbolName)
                    }
                }
            }
            .navigationTitle("対戦ルール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    GameRulesView()
}
