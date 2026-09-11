import SwiftUI
import PhotosUI
import UserNotifications

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
    @State private var readingDocument: LegalDocument?
    @State private var diagnostics: PushNotificationService.Diagnostics?
    @State private var isDiagnosing = false
    @State private var isRetryingSubscription = false
    @State private var isShowingInvite = false

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

                Section {
                    Button {
                        isShowingInvite = true
                    } label: {
                        Label(String(localized: "友達をアプリに招待"), systemImage: "qrcode")
                    }
                } footer: {
                    Text("QRコードやリンクで、まだこのアプリを入れていない人にTestFlightからインストールしてもらえます。")
                }

                notificationSection

                legalSection

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
            // 開いた時点で自動的に調べる. 「通知が来ない」ときに
            // ここを開けば原因が出ている状態にする.
            .task { await runDiagnostics() }
            .onChange(of: imagePickerItem) { _, newValue in
                guard let newValue else { return }
                Task { imageData = try? await newValue.loadTransferable(type: Data.self) }
            }
            .sheet(item: $readingDocument) { document in
                LegalDocumentScreen(document: document)
            }
            .sheet(isPresented: $isShowingInvite) {
                InviteFriendsView()
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
            Toggle(String(localized: "メッセージ"), isOn: $preferences.messagesEnabled)
            Toggle(String(localized: "本文を表示"), isOn: $preferences.showsMessagePreview)
                .disabled(!preferences.messagesEnabled)
                .padding(.leading, AppConstants.Layout.standardSpacing)

            Toggle(String(localized: "すれ違い通信"), isOn: $preferences.streetPassEnabled)

            Toggle(
                String(localized: "掲示板"),
                isOn: Binding(
                    get: { preferences.boardEnabled },
                    set: { newValue in
                        Task { await environment.pushService.setBoardNotificationsEnabled(newValue) }
                    }
                )
            )

            subscriptionStatusRow
        } header: {
            Text("通知")
        } footer: {
            Text("種類ごとに通知のオン・オフを選べます。メッセージの本文表示をオフにすると、ロック画面には送信者だけが表示されます。iPad を机に置いたままにすることが多い場合はオフをおすすめします。")
        }
    }

    /// 通知が届くまでの各段階を並べて出す.
    ///
    /// 通知は「許可 → 端末登録 → 購読 → 配信」の 4 段階を全部通らないと届かず,
    /// どこで切れても症状は同じ「通知が来ない」になる. 段階ごとに結果を出して,
    /// どこで止まっているのかを 1 画面で特定できるようにする.
    @ViewBuilder
    private var subscriptionStatusRow: some View {
        Button {
            Task { await runDiagnostics() }
        } label: {
            HStack {
                Label(String(localized: "通知の状態を調べる"), systemImage: "stethoscope")
                Spacer()
                if isDiagnosing { ProgressView() }
            }
        }
        .disabled(isDiagnosing)

        if let diagnostics {
            diagnosticRow(
                String(localized: "1. 通知の許可"),
                ok: diagnostics.authorization == .authorized,
                detail: authorizationDetail(diagnostics.authorization)
            )
            diagnosticRow(
                String(localized: "2. 端末の登録"),
                ok: diagnostics.deviceToken.isRegistered,
                detail: deviceTokenDetail(diagnostics.deviceToken)
            )
            diagnosticRow(
                String(localized: "3. サーバの購読"),
                ok: diagnostics.hasMessageSubscription,
                detail: subscriptionDetail(diagnostics)
            )

            if !diagnostics.isHealthy {
                Button(String(localized: "購読をもう一度設定する")) {
                    Task {
                        isRetryingSubscription = true
                        await store.configurePushSubscriptions()
                        await runDiagnostics()
                        isRetryingSubscription = false
                    }
                }
                .font(.footnote)
                .disabled(isRetryingSubscription)

                // 押した本人には成功も失敗も見えていなければ意味が無い.
                // configurePushSubscriptions() の結果はここでしか表示されないので,
                // 実際に起きたエラーをそのまま出す.
                if isRetryingSubscription {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("設定しています…")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                } else if case .failed(let error) = store.pushSubscriptionStatus {
                    Text("作り直しに失敗しました: \(error.errorDescription ?? String(localized: "不明なエラー"))")
                        .font(.caption)
                        .foregroundStyle(Palette.failure)
                }
            }

            Text(diagnostics.isHealthy
                 ? String(localized: "すべて有効です。それでも通知が来ない場合は、送信側が別の端末・別の Apple ID か、iPad が「おやすみモード」等になっていないか確認してください。")
                 : String(localized: "×の付いた段階が原因です。アプリを開いている間のメッセージ表示は、この設定に関係なく動きます。"))
                .font(.caption)
                .foregroundStyle(Palette.subdued)
        }
    }

    private func diagnosticRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Palette.success : Palette.failure)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func authorizationDetail(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            String(localized: "許可されています")
        case .denied:
            String(localized: "拒否されています。iPad の「設定」→「通知」→ アプリ で許可してください")
        case .notDetermined:
            String(localized: "まだ確認していません。チャットを一度開くと許可を求めます")
        @unknown default:
            String(localized: "不明")
        }
    }

    private func deviceTokenDetail(_ state: PushNotificationService.DeviceTokenState) -> String {
        switch state {
        case .registered(let suffix):
            String(localized: "APNs に登録済み(…\(suffix))")
        case .notRequested:
            String(localized: "まだ登録できていません。通信できる状態でアプリを開き直してください")
        case .failed(let reason):
            String(localized: "登録に失敗: \(reason)")
        }
    }

    private func subscriptionDetail(_ diagnostics: PushNotificationService.Diagnostics) -> String {
        if let error = diagnostics.subscriptionLookupError {
            return String(localized: "確認できませんでした: \(error)")
        }
        if diagnostics.hasMessageSubscription {
            if diagnostics.usesPerConversationSubscriptions {
                return String(localized: "会話ごとの購読で動いています(全 \(diagnostics.serverSubscriptionIDs.count) 件)")
            }
            return String(localized: "新着メッセージの購読があります(全 \(diagnostics.serverSubscriptionIDs.count) 件)")
        }
        return String(localized: "新着メッセージの購読がサーバにありません。下のボタンで作り直してください")
    }

    private func runDiagnostics() async {
        isDiagnosing = true
        defer { isDiagnosing = false }
        diagnostics = await environment.pushService.runDiagnostics(using: environment.backend)
    }

    /// 同意した規約をあとから読み返せるようにする.
    private var legalSection: some View {
        Section {
            Button {
                readingDocument = .termsOfService
            } label: {
                legalRow(String(localized: "利用規約"))
            }
            Button {
                readingDocument = .privacyPolicy
            } label: {
                legalRow(String(localized: "プライバシーポリシー"))
            }
        } header: {
            Text("規約")
        } footer: {
            Text("このアプリを使いはじめたときに同意いただいた内容です。")
        }
    }

    private func legalRow(_ title: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
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
