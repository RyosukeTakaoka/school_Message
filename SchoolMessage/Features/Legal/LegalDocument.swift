import Foundation

/// アプリ内に表示する法的文書(利用規約・プライバシーポリシー).
///
/// ## 本文を Swift の文字列で持つ理由
/// `docs/` にある Markdown をアプリのリソースとして同梱する案もあったが,
/// - リソースの追加は Xcode プロジェクトの構成に依存し, 取り込み漏れが
///   起きても「実行するまで気付けない」(法的文書が表示されないのは致命的)
/// - 端末がオフラインでも必ず読める必要がある
/// ことから, コードとして持ち, ビルドが通れば必ず存在する状態にしている.
///
/// ## `docs/` の Markdown との関係
/// `docs/PRIVACY_POLICY.md` / `docs/TERMS_OF_SERVICE.md` は Web 公開用
/// (App Store Connect が要求する URL)で, ここにあるのはアプリ内表示用.
/// **内容を変更するときは必ず両方を更新し, `ConsentStore.currentVersion` も
/// 上げること.** 表組みだけは画面幅に収まらないため, アプリ内では箇条書きに
/// 直してある.
struct LegalDocument: Identifiable, Sendable {

    let id: String
    /// 画面のタイトル.
    let title: String
    /// 「制定日: ...」などの補足行.
    let subtitle: String
    /// Markdown の部分集合で書いた本文.
    ///
    /// 対応している記法:
    /// - `## 見出し` / `### 小見出し`
    /// - `- 箇条書き`
    /// - `1. 番号付き`(そのまま段落として表示)
    /// - `**強調**` などのインライン記法(`AttributedString` が解釈する)
    /// - `---` 区切り線
    let body: String

    static let privacyPolicy = LegalDocument(
        id: "privacy",
        title: String(localized: "プライバシーポリシー"),
        subtitle: String(localized: "制定日: 2026年9月7日 / 最終改定日: 2026年9月8日"),
        body: LegalText.privacyPolicy
    )

    static let termsOfService = LegalDocument(
        id: "terms",
        title: String(localized: "利用規約"),
        subtitle: String(localized: "制定日: 2026年9月7日 / 最終改定日: 2026年9月8日"),
        body: LegalText.termsOfService
    )
}

/// 本文を画面に出せる単位へ分解したもの.
///
/// Markdown をそのまま `Text` に渡すと見出しや箇条書きが崩れるため,
/// 行単位で種類を判定してから組み立てる. 使う記法を限っているので,
/// 汎用の Markdown 実装を持ち込むより短く済み, 挙動も読める.
enum LegalBlock: Hashable {
    case heading(String)
    case subheading(String)
    case paragraph(String)
    case bullet(String)
    case divider

    /// 本文を上から順に解析する.
    static func parse(_ body: String) -> [LegalBlock] {
        var blocks: [LegalBlock] = []
        // 段落は空行で区切る. 途中で改行された行は 1 つの段落として繋ぐ.
        var pendingParagraph: [String] = []

        func flushParagraph() {
            guard !pendingParagraph.isEmpty else { return }
            blocks.append(.paragraph(pendingParagraph.joined(separator: " ")))
            pendingParagraph.removeAll()
        }

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
            } else if line == "---" {
                flushParagraph()
                blocks.append(.divider)
            } else if let text = line.strippingPrefix("### ") {
                flushParagraph()
                blocks.append(.subheading(text))
            } else if let text = line.strippingPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(text))
            } else if let text = line.strippingPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(text))
            } else {
                pendingParagraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}

private extension String {
    /// 接頭辞が一致すればそれを取り除いた残りを返す.
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
