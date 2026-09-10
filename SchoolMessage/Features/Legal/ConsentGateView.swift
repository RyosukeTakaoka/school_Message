import SwiftUI

/// 利用規約とプライバシーポリシーへの同意を求める画面.
///
/// アプリの他のどの画面よりも先に出す(iCloud の確認よりも前).
/// 一般的なアプリと同じく, 全文への導線とチェックボックスだけを置く,
/// 要点の要約は出さないシンプルな形にしている.
struct ConsentGateView: View {

    @Environment(ConsentStore.self) private var consent

    @State private var isAgreed = false
    @State private var readingDocument: LegalDocument?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing * 1.5) {
                    header
                    documentButtons
                    agreementControls
                }
                .padding(AppConstants.Layout.standardSpacing * 1.5)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.chatBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $readingDocument) { document in
            LegalDocumentScreen(document: document)
        }
    }

    // MARK: - 部品

    private var header: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(consent.needsReconsentAfterUpdate ? "規約が更新されました" : "はじめる前に")
                .font(.largeTitle.weight(.bold))

            Text(consent.needsReconsentAfterUpdate
                 ? "利用規約とプライバシーポリシーを改定しました。内容をご確認のうえ、あらためて同意をお願いします。"
                 : "このアプリを使うには、利用規約とプライバシーポリシーへの同意が必要です。")
                .font(.body)
                .foregroundStyle(Palette.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var documentButtons: some View {
        VStack(spacing: AppConstants.Layout.compactSpacing) {
            documentButton(.termsOfService)
            documentButton(.privacyPolicy)
        }
    }

    private func documentButton(_ document: LegalDocument) -> some View {
        Button {
            readingDocument = document
        } label: {
            HStack {
                Text(document.title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)
            }
            .padding(AppConstants.Layout.standardSpacing)
            .background(Palette.composerBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "全文を開きます"))
    }

    private var agreementControls: some View {
        VStack(spacing: AppConstants.Layout.standardSpacing) {
            Toggle(isOn: $isAgreed) {
                Text("利用規約とプライバシーポリシーに同意します")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)

            Button {
                consent.agree()
            } label: {
                Text("同意してはじめる")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isAgreed)

            Text("同意いただけない場合は、本アプリをご利用いただけません。")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

#Preview {
    // プレビューでの同意が実際の設定に残らないよう, 別の保存先を使う.
    ConsentGateView()
        .environment(ConsentStore(defaults: UserDefaults(suiteName: "preview") ?? .standard))
}
