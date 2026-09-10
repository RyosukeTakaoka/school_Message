import SwiftUI

/// 利用規約とプライバシーポリシーへの同意を求める画面.
///
/// アプリの他のどの画面よりも先に出す(iCloud の確認よりも前).
///
/// ## 要点を先に出している理由
/// 長い文書をそのまま出して「同意する」を押させても, 実際には読まれない.
/// それでは同意を取った形だけが残る. 特にこのアプリには
/// 「本文は開発者にも読めないが, 誰と誰がやり取りしたかは見える」
/// 「送信したメッセージは取り消せない」という, 利用者が知らないまま
/// 使い始めると不利益になりうる性質がある. そこで先に要点を提示し,
/// そのうえで全文へ進めるようにしている.
struct ConsentGateView: View {

    @Environment(ConsentStore.self) private var consent

    @State private var isAgreed = false
    @State private var readingDocument: LegalDocument?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing * 1.5) {
                    header
                    summary
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
                 : "Nexia を使うには、利用規約とプライバシーポリシーへの同意が必要です。大事な点を先にまとめました。")
                .font(.body)
                .foregroundStyle(Palette.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
            point(
                icon: "lock.fill",
                title: String(localized: "メッセージは暗号化されます"),
                detail: String(localized: "本文・写真・動画は端末の中で暗号化してから送るので、開発者にも読めません。")
            )
            point(
                icon: "eye.fill",
                title: String(localized: "隠れないものもあります"),
                detail: String(localized: "「誰が・いつ・誰と」やり取りしたか、表示名、プロフィール画像は暗号化されません。開発者はこれらを見られます。")
            )
            point(
                icon: "arrow.uturn.backward.circle.fill",
                title: String(localized: "取り消しても痕跡は残ります"),
                detail: String(localized: "送信から24時間は取り消せますが、相手の画面には「送信を取り消しました」と残ります。取り消したこと自体は隠せません。")
            )
            point(
                icon: "exclamationmark.triangle.fill",
                title: String(localized: "個人が無償で作ったアプリです"),
                detail: String(localized: "動作の保証はなく、不具合やデータの消失で損害が生じても、開発者は責任を負いません。緊急の連絡には使わないでください。")
            )
        }
        .padding(AppConstants.Layout.standardSpacing)
        .background(Palette.incomingBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppConstants.Layout.standardSpacing) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
