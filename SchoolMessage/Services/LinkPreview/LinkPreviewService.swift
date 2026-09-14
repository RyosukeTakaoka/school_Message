import Foundation

/// メッセージ・掲示板の本文に含まれる URL の, カード表示用の要約.
struct LinkPreview: Hashable, Sendable {
    let url: URL
    var title: String?
    var description: String?
    var imageURL: URL?
    /// サイト名(oEmbed の provider_name, または og:site_name).
    var siteName: String?
}

/// 本文の中から最初の URL を見つける.
enum LinkDetector {
    static func firstURL(in text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range), let url = match.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}

/// URL の要約を, oEmbed(対応サイトのみ) / Open Graph タグから作る.
///
/// ## なぜ 2 段構えか
/// oEmbed は YouTube・Vimeo など動画・音声系のサイトが公式に提供する
/// 要約 API で, 情報の質が高い(サムネイル・投稿者名まで取れる). ただし
/// 対応サイトが限られるので, それ以外の一般的な Web ページは HTML の
/// `<meta property="og:...">`(Open Graph)タグを軽く読み取って要約する.
///
/// ## HTML パーサを使わない理由
/// フルの HTML パーサ(サードパーティ製)を追加するほどの精度は要らず,
/// 欲しいのは `<meta>` タグの中身だけなので, 正規表現で軽量に済ませる.
actor LinkPreviewService {

    private var cache: [URL: LinkPreview] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func preview(for url: URL) async throws -> LinkPreview {
        if let cached = cache[url] { return cached }

        let result: LinkPreview
        if let provider = Self.oEmbedProvider(for: url) {
            do {
                result = try await fetchOEmbed(for: url, endpoint: provider)
            } catch {
                // oEmbed が使えない(非公開動画などで失敗する)場合は, 普通の
                // ページとして Open Graph を試す(何も出さないよりはよい).
                result = try await fetchOpenGraph(for: url)
            }
        } else {
            result = try await fetchOpenGraph(for: url)
        }

        cache[url] = result
        return result
    }

    // MARK: - oEmbed

    /// 対応が分かっている主要サイトだけを狙い撃ちする(未知のサイトに oEmbed
    /// discovery を試みるのはコストが高い割に対応漏れの心配が大きいため).
    private static let oEmbedEndpoints: [(hosts: [String], endpoint: String)] = [
        (["youtube.com", "youtu.be"], "https://www.youtube.com/oembed"),
        (["vimeo.com"], "https://vimeo.com/api/oembed.json"),
        (["soundcloud.com"], "https://soundcloud.com/oembed"),
        (["flickr.com"], "https://www.flickr.com/services/oembed")
    ]

    private static func oEmbedProvider(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return oEmbedEndpoints.first { provider in
            provider.hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        }?.endpoint
    }

    private struct OEmbedResponse: Decodable {
        let title: String?
        let authorName: String?
        let providerName: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case providerName = "provider_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    private func fetchOEmbed(for url: URL, endpoint: String) async throws -> LinkPreview {
        guard var components = URLComponents(string: endpoint) else {
            throw AppError.underlying(String(localized: "リンクの情報を取得できませんでした"))
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let requestURL = components.url else {
            throw AppError.underlying(String(localized: "リンクの情報を取得できませんでした"))
        }
        let (data, response) = try await session.data(from: requestURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.underlying(String(localized: "リンクの情報を取得できませんでした"))
        }
        let decoded = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        return LinkPreview(
            url: url,
            title: decoded.title,
            description: decoded.authorName,
            imageURL: decoded.thumbnailURL.flatMap(URL.init(string:)),
            siteName: decoded.providerName
        )
    }

    // MARK: - Open Graph

    private func fetchOpenGraph(for url: URL) async throws -> LinkPreview {
        var request = URLRequest(url: url)
        // ページ全体を読み込む必要はなく, <head> の meta タグさえ読めればよいので,
        // 対応しているサーバには先頭だけを返してもらう(対応していなければ無視される).
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw AppError.underlying(String(localized: "リンクの情報を取得できませんでした"))
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AppError.underlying(String(localized: "リンクの情報を取得できませんでした"))
        }

        let meta = Self.metaTagContents(in: html, matching: [
            "og:title", "og:description", "og:image", "og:site_name", "description"
        ])
        let title = meta["og:title"] ?? Self.titleTagText(in: html)
        let imageURLString = meta["og:image"]
        let imageURL = imageURLString.flatMap { URL(string: $0, relativeTo: url) }?.absoluteURL

        return LinkPreview(
            url: url,
            title: title.map(Self.decodingHTMLEntities),
            description: (meta["og:description"] ?? meta["description"]).map(Self.decodingHTMLEntities),
            imageURL: imageURL,
            siteName: meta["og:site_name"].map(Self.decodingHTMLEntities) ?? url.host
        )
    }

    /// `<meta property="..." content="...">` (`name="..."` も可)から,
    /// 指定したキーに一致するものだけを拾う. 属性の並び順には依存しない.
    private static func metaTagContents(in html: String, matching keys: [String]) -> [String: String] {
        var result: [String: String] = [:]
        guard let tagRegex = try? NSRegularExpression(pattern: "<meta\\s+[^>]*>", options: [.caseInsensitive]) else {
            return result
        }
        let range = NSRange(html.startIndex..., in: html)
        tagRegex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let tagRange = Range(match.range, in: html) else { return }
            let tag = String(html[tagRange])
            guard let key = (attributeValue(in: tag, attribute: "property") ?? attributeValue(in: tag, attribute: "name"))?.lowercased(),
                  keys.contains(key),
                  let content = attributeValue(in: tag, attribute: "content")
            else { return }
            result[key] = content
        }
        return result
    }

    private static func attributeValue(in tag: String, attribute: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(attribute)\\s*=\\s*\"([^\"]*)\"|\(attribute)\\s*=\\s*'([^']*)'",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for groupIndex in [1, 2] {
            if let group = Range(match.range(at: groupIndex), in: tag) {
                return String(tag[group])
            }
        }
        return nil
    }

    private static func titleTagText(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), let group = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[group]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// よく使われる HTML 実体参照だけ, 簡易に元の文字へ戻す
    /// (フル HTML パーサを使わないための割り切り).
    private static func decodingHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
