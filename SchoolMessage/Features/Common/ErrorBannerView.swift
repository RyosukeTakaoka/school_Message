import SwiftUI

/// 画面上部に出すエラー表示.
///
/// アラートで操作を止めるのではなくバナーにするのは, チャットの流れを
/// 止めないため. 原因と次の行動が同時に見えるように, 説明文と対処法を並べる.
struct ErrorBannerView: View {

    let error: AppError
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppConstants.Layout.standardSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.failure)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? String(localized: "エラーが発生しました"))
                    .font(.subheadline.weight(.semibold))
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "閉じる"))
        }
        .padding(AppConstants.Layout.standardSpacing)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.failure.opacity(0.35))
        }
        .padding(.horizontal, AppConstants.Layout.standardSpacing)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

/// オフライン中であることを控えめに知らせる帯.
struct OfflineBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("オフライン - 接続が戻ると自動で送信します")
        }
        .font(.caption)
        .foregroundStyle(Palette.subdued)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Palette.composerBackground)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack {
        ErrorBannerView(error: .offline) {}
        OfflineBar()
    }
}
