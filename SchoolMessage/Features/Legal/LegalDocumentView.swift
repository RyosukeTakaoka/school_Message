import SwiftUI

/// 法的文書の本文を表示する.
///
/// 同意画面からも, あとからプロフィール画面からも同じ表示を使う.
/// 文字サイズは Dynamic Type に追従し, VoiceOver では見出しとして読まれる.
struct LegalDocumentView: View {

    let document: LegalDocument

    /// 解析結果. 本文は長いので, body の評価ごとに解析し直さないよう
    /// 生成時に一度だけ組み立てる.
    private let blocks: [LegalBlock]

    init(document: LegalDocument) {
        self.document = document
        self.blocks = LegalBlock.parse(document.body)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                Text(document.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)

                // 位置が変わらないため, 並び順をそのまま識別子にする.
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(AppConstants.Layout.standardSpacing)
            // 長文なので, 大画面で 1 行が長くなりすぎないように上限を設ける.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.chatBackground)
    }

    @ViewBuilder
    private func view(for block: LegalBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.bold))
                .padding(.top, AppConstants.Layout.compactSpacing)
                .accessibilityAddTraits(.isHeader)

        case .subheading(let text):
            Text(text)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            Text(styled(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("・")
                    .foregroundStyle(Palette.subdued)
                    .accessibilityHidden(true)
                Text(styled(text))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            Divider().padding(.vertical, AppConstants.Layout.compactSpacing)
        }
    }

    /// `**強調**` などのインライン記法を反映する.
    /// 解釈できない場合は元の文字列をそのまま出す(表示が消えるより良い).
    private func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// 単独の画面として開くときの入れ物(プロフィール画面から使う).
struct LegalDocumentScreen: View {

    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LegalDocumentView(document: document)
                .navigationTitle(document.title)
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
    LegalDocumentScreen(document: .termsOfService)
}
