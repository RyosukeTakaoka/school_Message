import SwiftUI

/// メッセージ・掲示板の本文に含まれる URL を, タイトル・説明・画像つきの
/// カードにして表示する(oEmbed / Open Graph. `LinkPreviewService` 参照).
///
/// 読み込み中や取得に失敗した場合は何も出さない. 本文自体はそのまま読めるので,
/// プレビューが出ないだけで困らせないため(エラーで埋めるより静かな方がよい).
struct LinkPreviewCard: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    let url: URL

    @State private var preview: LinkPreview?

    private var service: LinkPreviewService { environment.linkPreviewService }

    var body: some View {
        Group {
            if let preview {
                card(preview)
            }
        }
        .task(id: url) {
            preview = try? await service.preview(for: url)
        }
    }

    private func card(_ preview: LinkPreview) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if let imageURL = preview.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.gray.opacity(0.12)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title ?? url.host ?? url.absoluteString)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let description = preview.description, !description.isEmpty {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(Palette.subdued)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let siteName = preview.siteName, !siteName.isEmpty {
                        Text(siteName)
                            .font(.caption2)
                            .foregroundStyle(Palette.subdued)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Palette.incomingBubble.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
