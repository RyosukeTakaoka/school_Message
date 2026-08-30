import SwiftUI

/// プロフィール画像. 画像が無いときは頭文字を出す.
struct AvatarView: View {

    let imageData: Data?
    let fallbackText: String
    let seed: String
    var size: CGFloat = AppConstants.Layout.avatarMedium

    var body: some View {
        Group {
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Palette.avatarBackground(for: seed)
                    .overlay {
                        Text(fallbackText)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // 画像そのものは情報を持たないので, 読み上げ対象から外す.
        // 名前は隣のテキストが読み上げる.
        .accessibilityHidden(true)
    }
}

extension AvatarView {
    init(profile: UserProfile, size: CGFloat = AppConstants.Layout.avatarMedium) {
        self.init(
            imageData: profile.avatarData,
            fallbackText: profile.initials,
            seed: profile.id.rawValue,
            size: size
        )
    }
}

#Preview {
    HStack {
        AvatarView(imageData: nil, fallbackText: "田", seed: "tanaka", size: 48)
        AvatarView(imageData: nil, fallbackText: "佐", seed: "sato", size: 48)
        AvatarView(imageData: nil, fallbackText: "2", seed: "group", size: 48)
    }
    .padding()
}
