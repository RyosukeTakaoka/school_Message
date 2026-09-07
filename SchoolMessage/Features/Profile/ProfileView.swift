import SwiftUI
import PhotosUI

/// 自分のプロフィールと設定.
struct ProfileView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var imageData: Data?
    @State private var imagePickerItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var isConfirmingSignOut = false
    @State private var didCopyHandle = false

    private var store: ChatStore { environment.store }

    private var hasChanges: Bool {
        guard let profile = store.myProfile else { return false }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed != profile.displayName && !trimmed.isEmpty) || imageData != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: AppConstants.Layout.standardSpacing) {
                        PhotosPicker(selection: $imagePickerItem, matching: .images) {
                            AvatarView(
                                imageData: imageData ?? store.myProfile?.avatarData,
                                fallbackText: store.myProfile?.initials ?? "?",
                                seed: store.myProfile?.id.rawValue ?? "me",
                                size: AppConstants.Layout.avatarLarge
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                            }
                        }
                        .accessibilityLabel(String(localized: "プロフィール画像を変更"))
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section(String(localized: "表示名")) {
                    TextField(String(localized: "表示名"), text: $displayName)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    HStack {
                        Text("ユーザID")
                        Spacer()
                        Text("@\(store.myProfile?.handle ?? "-")")
                            .foregroundStyle(Palette.subdued)
                            .textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = store.myProfile?.handle
                        didCopyHandle = true
                    } label: {
                        Label(
                            didCopyHandle
                                ? String(localized: "コピーしました")
                                : String(localized: "ユーザIDをコピー"),
                            systemImage: didCopyHandle ? "checkmark" : "doc.on.doc"
                        )
                    }
                } footer: {
                    Text("友達にこのユーザIDを伝えると、検索して追加してもらえます。ユーザIDは変更できません。")
                }

                notificationSection

                Section {
                    Button(String(localized: "ログアウト"), role: .destructive) {
                        isConfirmingSignOut = true
                    }
                } footer: {
                    Text("ログアウトしても、この iPad に保存された鍵は残ります。同じ Apple ID で再ログインすれば過去のメッセージを読めます。")
                }
            }
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "保存"), action: save)
                            .disabled(!hasChanges)
                    }
                }
            }
            .onAppear {
                displayName = store.myProfile?.displayName ?? ""
            }
            .onChange(of: imagePickerItem) { _, newValue in
                guard let newValue else { return }
                Task { imageData = try? await newValue.loadTransferable(type: Data.self) }
            }
            .confirmationDialog(
                String(localized: "ログアウトしますか?"),
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button(String(localized: "ログアウト"), role: .destructive) {
                    Task {
                        await store.signOut()
                        dismiss()
                    }
                }
                Button(String(localized: "キャンセル"), role: .cancel) {}
            }
        }
    }

    private var notificationSection: some View {
        @Bindable var preferences = environment.notificationPreferences
        return Section {
            Toggle(String(localized: "通知を受け取る"), isOn: $preferences.isEnabled)
            Toggle(String(localized: "通知に本文を表示"), isOn: $preferences.showsMessagePreview)
                .disabled(!preferences.isEnabled)
            subscriptionStatusRow
        } header: {
            Text("通知")
        } footer: {
            Text("本文の表示をオフにすると、ロック画面には送信者だけが表示されます。iPad を机に置いたままにすることが多い場合はオフをおすすめします。")
        }
    }

    /// 新着を知らせる仕組み(プッシュ購読)が使えているか.
    ///
    /// ここが失敗していると, アプリを開いていない間の通知が一切届かない.
    /// 以前は失敗してもログに出るだけで気付けなかったため, 画面に出す.
    @ViewBuilder
    private var subscriptionStatusRow: some View {
        switch store.pushSubscriptionStatus {
        case .unknown, .configuring:
            HStack {
                Text("新着の受信設定")
                Spacer()
                ProgressView()
            }

        case .active:
            HStack {
                Text("新着の受信設定")
                Spacer()
                Label(String(localized: "有効"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(Palette.success)
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
                HStack {
                    Text("新着の受信設定")
                    Spacer()
                    Label(String(localized: "未設定"), systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(Palette.failure)
                }
                Text(error.errorDescription ?? String(localized: "設定できませんでした"))
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Text("この状態でも、アプリを開いている間はメッセージが自動で表示されます。届かないのはアプリを閉じている間の通知だけです。")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Button(String(localized: "もう一度設定する")) {
                    Task { await store.configurePushSubscriptions() }
                }
                .font(.footnote)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            await store.updateProfile(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                avatarData: imageData
            )
            imageData = nil
            imagePickerItem = nil
            isSaving = false
        }
    }
}

#Preview {
    ProfileView()
        .environment(AppEnvironment.preview())
}
