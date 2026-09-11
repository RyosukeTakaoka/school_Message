import SwiftUI

/// 友達をこのアプリ(TestFlight 経由)に招待する画面.
///
/// QR コードと同じ内容のリンクを両方出しておくのは, 「近くにいる相手には
/// 読み取ってもらう」「離れた相手にはリンクを送る」のどちらにも対応するため.
struct InviteFriendsView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var didCopyLink = false

    private var inviteURL: URL? { URL(string: AppConstants.testFlightInviteURL) }
    private var qrImage: UIImage? { QRCodeGenerator.image(for: AppConstants.testFlightInviteURL) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppConstants.Layout.standardSpacing * 2) {
                    VStack(spacing: 6) {
                        Text("友達をアプリに招待")
                            .font(.title2.weight(.bold))
                        Text("このQRコードを読み取るか、下のリンクを送ると、TestFlightからこのアプリをインストールしてもらえます。")
                            .font(.subheadline)
                            .foregroundStyle(Palette.subdued)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, AppConstants.Layout.standardSpacing)

                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(AppConstants.Layout.standardSpacing)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Palette.subdued.opacity(0.2))
                            }
                            .accessibilityLabel(String(localized: "招待用のQRコード"))
                    } else {
                        // まず起きないが, 生成に失敗してもリンク自体は使えるようにしておく.
                        ContentUnavailableView(
                            String(localized: "QRコードを作れませんでした"),
                            systemImage: "qrcode"
                        )
                        .frame(height: 220)
                    }

                    VStack(spacing: AppConstants.Layout.standardSpacing) {
                        Text(AppConstants.testFlightInviteURL)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Palette.subdued)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)

                        HStack(spacing: AppConstants.Layout.standardSpacing) {
                            Button {
                                UIPasteboard.general.string = AppConstants.testFlightInviteURL
                                didCopyLink = true
                            } label: {
                                Label(
                                    didCopyLink ? String(localized: "コピーしました") : String(localized: "リンクをコピー"),
                                    systemImage: didCopyLink ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .buttonStyle(.bordered)

                            if let inviteURL {
                                ShareLink(item: inviteURL) {
                                    Label(String(localized: "共有"), systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    Text("TestFlight は無料の Apple 公式アプリです。招待された人は、App Store で「TestFlight」を入れてから、このリンクまたは QR コードを開いてください。")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppConstants.Layout.standardSpacing)
                }
                .padding(.vertical, AppConstants.Layout.standardSpacing * 2)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("招待")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    InviteFriendsView()
}
