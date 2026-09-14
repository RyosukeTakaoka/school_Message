import Foundation

/// Giphy の検索 API から返ってくる, 1 本の GIF.
///
/// Giphy の JSON は `width` / `height` / `size` を(数値ではなく)文字列で
/// 返してくるため, 素直に `Decodable` に任せられない. `GiphyRendition` の
/// カスタム `init(from:)` で両対応にしている.
struct GiphyGif: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let images: GiphyImages

    static func == (lhs: GiphyGif, rhs: GiphyGif) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 一覧(グリッド)でのプレビュー用. 小さくて軽いものを選ぶ.
    var previewRendition: GiphyRendition? {
        images.fixedWidthSmall ?? images.fixedWidth
    }

    /// 実際に送信するときに使う本体. 大きすぎない「downsized」を優先する.
    var sendRendition: GiphyRendition? {
        images.downsized ?? images.fixedWidth ?? images.original
    }
}

struct GiphyImages: Decodable, Hashable {
    let fixedWidthSmall: GiphyRendition?
    let fixedWidth: GiphyRendition?
    let downsized: GiphyRendition?
    let original: GiphyRendition?

    enum CodingKeys: String, CodingKey {
        case fixedWidthSmall = "fixed_width_small"
        case fixedWidth = "fixed_width"
        case downsized
        case original
    }
}

/// 1 サイズぶんの画像情報.
struct GiphyRendition: Decodable, Hashable {
    let url: URL
    let width: Int
    let height: Int
    /// バイト数. Giphy が返さないこともあるので optional.
    let size: Int?

    private enum CodingKeys: String, CodingKey {
        case url, width, height, size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        width = try Self.decodeInt(container, .width) ?? 0
        height = try Self.decodeInt(container, .height) ?? 0
        size = try Self.decodeInt(container, .size)
    }

    /// Giphy は数値を文字列("200")で返すので, 数値・文字列のどちらでも読めるようにする.
    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Int? {
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intValue
        }
        guard let stringValue = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return Int(stringValue)
    }
}

private struct GiphySearchResponse: Decodable {
    let data: [GiphyGif]
}

/// Giphy の検索 API を叩く.
///
/// キーを持たない(未設定の)状態でも使い方自体は成立させ, 呼び出し時に
/// 分かりやすいエラーを返す(アプリ全体を壊さないため).
actor GiphyService {

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    /// 語句で検索する.
    func search(query: String, limit: Int = 24) async throws -> [GiphyGif] {
        try await request(path: "search", query: query, limit: limit)
    }

    /// 検索前に出す「話題の GIF」.
    func trending(limit: Int = 24) async throws -> [GiphyGif] {
        try await request(path: "trending", query: nil, limit: limit)
    }

    private func request(path: String, query: String?, limit: Int) async throws -> [GiphyGif] {
        guard isConfigured else {
            throw AppError.underlying(
                String(localized: "GIF検索を使うには Giphy の API キーの設定が必要です(docs/SETUP.md 参照)")
            )
        }
        guard var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)") else {
            throw AppError.underlying(String(localized: "GIFの検索に失敗しました"))
        }
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            // 学校で使うアプリのため, 検索結果はレーティングで絞る.
            URLQueryItem(name: "rating", value: "g")
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw AppError.underlying(String(localized: "GIFの検索に失敗しました"))
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.underlying(String(localized: "GIFの検索に失敗しました"))
        }
        let decoded = try JSONDecoder().decode(GiphySearchResponse.self, from: data)
        return decoded.data
    }
}
