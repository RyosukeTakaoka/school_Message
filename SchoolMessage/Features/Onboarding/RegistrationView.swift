import SwiftUI
import PhotosUI

/// 初回のプロフィール登録.
///
/// サインインは iCloud アカウントで済んでいるので, ここで聞くのは
/// 「友達から見つけてもらうための ID」と「表示名」だけにする.
struct RegistrationView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var handle = ""
    @State private var displayName = ""
    @State private var imageData: Data?
    @State private var imagePickerItem: PhotosPickerItem?
    @State private var isSubmitting = false
    @State private var validationMessage: String?

    private var store: ChatStore { environment.store }

    private var canSubmit: Bool {
        !isSubmitting
            && !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: AppConstants.Layout.standardSpacing) {
                        PhotosPicker(selection: $imagePickerItem, matching: .images) {
                            AvatarView(
                                imageData: imageData,
                                fallbackText: displayName.isEmpty ? "?" : String(displayName.prefix(1)),
                                seed: handle.isEmpty ? "new" : handle,
                                size: AppConstants.Layout.avatarLarge
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                            }
                        }
                        .accessibilityLabel(String(localized: "プロフィール画像を選ぶ"))
                        Text("あとから変更できます")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField(String(localized: "表示名(例: 田中)"), text: $displayName)
                } header: {
                    Text("表示名")
                } footer: {
                    Text("チャットで友達に表示される名前です。")
                }

                Section {
                    TextField(String(localized: "ユーザID(例: tanaka_2a)"), text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("ユーザID")
                } footer: {
                    Text("英小文字・数字・_ が使えます。友達はこの ID であなたを検索します。あとから変更できません。")
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(Palette.failure)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(action: submit) {
                        if isSubmitting {
                            HStack {
                                ProgressView()
                                Text("登録中…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("はじめる").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("プロフィールを登録")
            .onChange(of: imagePickerItem) { _, newValue in
                guard let newValue else { return }
                Task { imageData = try? await newValue.loadTransferable(type: Data.self) }
            }
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
        }
    }

    private func submit() {
        // 通信する前にクライアント側で検証し, 無駄な往復とエラー待ちを減らす.
        do {
            _ = try UserProfile.validateDisplayName(displayName)
            _ = try UserProfile.validateHandle(handle)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        isSubmitting = true
        Task {
            await store.register(
                handle: handle,
                displayName: displayName,
                avatarData: imageData
            )
            isSubmitting = false
        }
    }
}

#Preview {
    RegistrationView()
        .environment(AppEnvironment.preview())
}
