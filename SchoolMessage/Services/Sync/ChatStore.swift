import Foundation
import Observation

/// アプリの状態を一元管理するストア.
///
/// View は状態を読むだけにし, 取得・送信・整合性の維持はここに集約する.
/// `@MainActor` に置いているのは, 参照される場所がすべて UI であり,
/// 並行アクセスの調停コストを払う価値がないため. 重い処理(暗号化・圧縮・通信)は
/// それぞれ actor に逃がしてあるので, メインスレッドは待つだけになる.
@MainActor
@Observable
final class ChatStore {

    /// アプリ全体の状態遷移.
    enum Phase: Equatable {
        case launching
        /// iCloud にサインインしていない等, 先に解決が必要な状態.
        case blocked(AppError)
        /// サインイン済みだがプロフィール未登録.
        case needsRegistration
        case ready
    }

    // MARK: - 公開状態

    private(set) var phase: Phase = .launching
    private(set) var myProfile: UserProfile?
    var conversations: [Conversation] = []
    private(set) var friends: [UserProfile] = []
    /// 取得済みユーザの索引. 拡張からも書き込むため setter を絞っていない.
    var profilesByID: [UserID: UserProfile] = [:]
    // 以下 3 つは `ChatStore+Messaging.swift` の拡張からも更新するため
    // `private(set)` にしていない. View 側からは読み取り専用として扱い,
    // 変更は必ずストアのメソッド経由で行うこと.
    var messagesByConversation: [ConversationID: [Message]] = [:]
    var loadingConversationIDs: Set<ConversationID> = []
    /// これ以上さかのぼれる履歴があるか.
    var hasMoreHistory: Set<ConversationID> = []

    private(set) var isRefreshingConversations = false

    /// 画面上部に出す一時的なエラー.
    var banner: AppError?

    /// 右ペインに表示している会話.
    var selectedConversationID: ConversationID?

    /// 通知タップで開くよう要求されたチャット.
    /// `PushNotificationService` が設定し, `RootView` が消費する.
    var pendingNotificationConversationID: ConversationID?

    /// プッシュ購読(新着を知らせる仕組み)の状態.
    ///
    /// 購読の作成に失敗してもアプリはポーリングで動き続けるため, 以前は
    /// 失敗がログにしか出ず「通知だけが永久に来ない」状態に気付けなかった.
    /// 画面に出せるよう状態として持つ.
    enum PushSubscriptionStatus: Equatable {
        case unknown
        case configuring
        case active
        case failed(AppError)
    }

    private(set) var pushSubscriptionStatus: PushSubscriptionStatus = .unknown

    // MARK: - 依存

    let backend: any ChatBackend
    private let outbox: Outbox
    private let mediaProcessor: MediaProcessor
    private let mediaStore: MediaStore
    private let crypto: CryptoService
    private let networkMonitor: NetworkMonitor

    // 画面が観測する必要のない内部状態は追跡対象から外す.
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(
        backend: any ChatBackend,
        outbox: Outbox,
        mediaProcessor: MediaProcessor,
        mediaStore: MediaStore,
        crypto: CryptoService,
        networkMonitor: NetworkMonitor
    ) {
        self.backend = backend
        self.outbox = outbox
        self.mediaProcessor = mediaProcessor
        self.mediaStore = mediaStore
        self.crypto = crypto
        self.networkMonitor = networkMonitor

        networkMonitor.onReconnect = { [weak self] in
            self?.flushOutbox()
        }
    }

    /// 監視を止める. アプリ終了時やログアウト時に呼ぶ.
    ///
    /// `deinit` では行わない — `@MainActor` に隔離されたプロパティに
    /// deinit から触るのは並行性の観点で扱いが難しく, 明示的に止めるほうが安全.
    func stop() {
        eventTask?.cancel()
        pollTask?.cancel()
        flushTask?.cancel()
        eventTask = nil
        pollTask = nil
        flushTask = nil
    }

    // MARK: - 起動

    /// アプリ起動時に 1 回だけ呼ぶ.
    func start() async {
        mediaStore.purgeScratch()
        await outbox.load()

        do {
            let status = try await backend.accountStatus()
            switch status {
            case .noAccount:
                phase = .blocked(.iCloudAccountUnavailable)
                return
            case .restricted:
                phase = .blocked(.iCloudAccountRestricted)
                return
            case .temporarilyUnavailable:
                phase = .blocked(.timedOut)
                return
            case .available:
                break
            }

            guard let profile = try await backend.fetchMyProfile() else {
                phase = .needsRegistration
                return
            }
            myProfile = profile
            profilesByID[profile.id] = profile
            phase = .ready
        } catch {
            phase = .blocked(AppError.wrap(error))
            return
        }

        await afterSignIn()
    }

    /// プロフィール登録.
    func register(handle: String, displayName: String, avatarData: Data?) async {
        do {
            let compressed = try await compressedAvatar(avatarData)
            let profile = try await backend.registerProfile(
                handle: handle,
                displayName: displayName,
                avatarData: compressed
            )
            myProfile = profile
            profilesByID[profile.id] = profile
            phase = .ready
            await afterSignIn()
        } catch {
            banner = AppError.wrap(error)
        }
    }

    func updateProfile(displayName: String?, avatarData: Data?) async {
        do {
            let compressed = try await compressedAvatar(avatarData)
            let profile = try await backend.updateProfile(displayName: displayName, avatarData: compressed)
            myProfile = profile
            profilesByID[profile.id] = profile
        } catch {
            banner = AppError.wrap(error)
        }
    }

    private func compressedAvatar(_ data: Data?) async throws -> Data? {
        guard let data else { return nil }
        return try await mediaProcessor.prepareAvatarData(originalData: data)
    }

    /// サインイン後の共通処理.
    private func afterSignIn() async {
        startObservingBackendEvents()
        startPolling()

        await refreshConversations()
        await refreshFriends()
        flushOutbox()

        await configurePushSubscriptions()
    }

    /// プッシュ購読を用意する.
    ///
    /// 失敗してもアプリは動く(定期ポーリングで新着に気付く)が, 通知は届かなく
    /// なるため, 結果を状態として残してプロフィール画面から確認できるようにする.
    /// 新しい会話ができたときに購読を張り直す.
    ///
    /// 会話ごとの購読で動いている場合, 新しい会話の分は作られていないため
    /// そのままでは通知が来ない. グローバルな購読で動いている場合は
    /// 何も変わらないので, どちらでも安全に呼べる.
    private func resubscribeForNewConversation() async {
        guard pushSubscriptionStatus == .active else { return }
        try? await backend.configureSubscriptions()
    }

    func configurePushSubscriptions() async {
        pushSubscriptionStatus = .configuring
        do {
            try await backend.configureSubscriptions()
            pushSubscriptionStatus = .active
        } catch {
            let appError = AppError.wrap(error)
            Log.push.notice("push subscriptions unavailable; falling back to polling")
            pushSubscriptionStatus = .failed(appError)
        }
    }

    /// ログアウト. 端末に残る復号済みデータを片付ける.
    func signOut() async {
        eventTask?.cancel()
        pollTask?.cancel()
        await crypto.clearCachedConversationKeys()
        myProfile = nil
        conversations = []
        friends = []
        messagesByConversation = [:]
        profilesByID = [:]
        selectedConversationID = nil
        phase = .needsRegistration
    }

    // MARK: - 変更の購読

    private func startObservingBackendEvents() {
        eventTask?.cancel()
        let stream = backend.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: BackendEvent) async {
        switch event {
        case .messagesChanged(let conversationID):
            await refreshMessages(in: conversationID)
            await refreshConversations()
        case .conversationsChanged:
            await refreshConversations()
        case .profilesChanged:
            await refreshFriends()
        }
    }

    /// プッシュが届かない環境(通知を許可していない, サイレント通知が抑制された等)への保険.
    ///
    /// チャットを開いている間は間隔を縮め, 相手の新着メッセージが
    /// プッシュ通知の到達を待たずに画面へ反映されるようにする.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var lastListRefresh = Date.now
            var lastRevisionCheck = Date.now
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.selectedConversationID == nil
                    ? AppConstants.Timing.fallbackPollInterval
                    : AppConstants.Timing.activeConversationPollInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard self.networkMonitor.isOnline else { continue }

                // 短い間隔で回すのは開いている会話だけにする.
                // 一覧の取得は問い合わせが多く, 数秒ごとに実行すると
                // CloudKit への負荷と電池の消費が見合わないため.
                if let selected = self.selectedConversationID {
                    await self.refreshMessages(in: selected)

                    // 送信取り消しは既存メッセージの書き換えとして届くので,
                    // 新着の取得とは別に確認する.
                    if Date.now.timeIntervalSince(lastRevisionCheck) >= AppConstants.Timing.revisionCheckInterval {
                        lastRevisionCheck = .now
                        await self.reconcileMessages(in: selected)
                    }
                }
                if Date.now.timeIntervalSince(lastListRefresh) >= AppConstants.Timing.fallbackPollInterval {
                    lastListRefresh = .now
                    await self.refreshConversations()
                }
            }
        }
    }

    /// アプリが前面に戻ったときの更新.
    func handleForeground() {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshConversations()
            if let selected = self.selectedConversationID {
                await self.refreshMessages(in: selected)
                await self.reconcileMessages(in: selected)
                await self.markSelectedConversationRead()
            }
            self.flushOutbox()
        }
    }

    // MARK: - 会話

    func refreshConversations() async {
        guard phase == .ready else { return }
        isRefreshingConversations = true
        defer { isRefreshingConversations = false }

        do {
            var fetched = try await backend.fetchConversations()
            // 他の参加者の既読位置は会話ごとに個別取得しているため, 一覧の
            // 取得結果には入っていない. そのまま入れ替えると開いているチャットの
            // 「既読」が定期更新のたびに消えてしまうので, 既に持っていれば引き継ぐ.
            let knownReceipts = Dictionary(
                conversations.map { ($0.id, $0.readReceipts) },
                uniquingKeysWith: { current, _ in current }
            )
            for index in fetched.indices where fetched[index].readReceipts.isEmpty {
                fetched[index].readReceipts = knownReceipts[fetched[index].id] ?? [:]
            }
            conversations = fetched
            await loadMissingProfiles(for: fetched)
        } catch {
            let appError = AppError.wrap(error)
            // オフライン時は既に表示している一覧をそのまま残す.
            if appError != .offline {
                banner = appError
            }
        }
    }

    private func loadMissingProfiles(for conversations: [Conversation]) async {
        let needed = Set(conversations.flatMap(\.participantIDs)).subtracting(profilesByID.keys)
        guard !needed.isEmpty else { return }
        do {
            let profiles = try await backend.fetchProfiles(ids: Array(needed))
            for profile in profiles {
                profilesByID[profile.id] = profile
            }
        } catch {
            Log.sync.notice("could not load some profiles")
        }
    }

    func refreshFriends() async {
        guard phase == .ready else { return }
        do {
            let fetched = try await backend.fetchFriends()
            friends = fetched
            for profile in fetched {
                profilesByID[profile.id] = profile
            }
        } catch {
            Log.sync.notice("could not refresh friends")
        }
    }

    func conversation(_ id: ConversationID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// グループに入れられる相手の候補.
    ///
    /// 「友達」だけでは足りない. `Friendship` は追加した側にしか作られないため,
    /// 相手から追加されて始まったチャットの相手は, 現に毎日やり取りしていても
    /// 自分の友達一覧には出てこない. その状態で「まだ友達がいません」と出ると,
    /// 目の前にチャットがあるのにグループを作れず, 理由も分からない.
    ///
    /// そこで, 友達に加えて **すでに会話がある相手** も候補に含める.
    /// 会話の相手は当然「知っている人」であり, 候補から外す理由がない.
    var groupMemberCandidates: [UserProfile] {
        guard let me = myProfile?.id else { return [] }

        var candidateIDs = Set(friends.map(\.id))
        for conversation in conversations {
            candidateIDs.formUnion(conversation.participantIDs)
        }
        candidateIDs.remove(me)

        // プロフィールが取れていない相手は名前もアイコンも出せないので除く
        // (会話一覧の取得時に `loadMissingProfiles` で埋めている).
        return candidateIDs
            .compactMap { profilesByID[$0] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// チャット一覧・ヘッダに出す名前.
    func title(for conversation: Conversation) -> String {
        if let title = conversation.title, !title.isEmpty { return title }
        guard let me = myProfile?.id else { return String(localized: "チャット") }

        switch conversation.kind {
        case .direct:
            if let counterpart = conversation.counterpartID(for: me) {
                return profilesByID[counterpart]?.displayName ?? String(localized: "友達")
            }
            return String(localized: "チャット")
        case .group:
            // 名前未設定のグループはメンバー名を並べる.
            let names = conversation.participantIDs
                .filter { $0 != me }
                .compactMap { profilesByID[$0]?.displayName }
                .prefix(3)
            return names.isEmpty ? String(localized: "グループ") : names.joined(separator: "、")
        }
    }

    /// 1 対 1 のときは相手のプロフィール(アバター表示に使う).
    func counterpartProfile(for conversation: Conversation) -> UserProfile? {
        guard conversation.kind == .direct, let me = myProfile?.id else { return nil }
        return conversation.counterpartID(for: me).flatMap { profilesByID[$0] }
    }

    func members(of conversation: Conversation) -> [UserProfile] {
        conversation.participantIDs.compactMap { profilesByID[$0] }
    }

    func displayName(for userID: UserID) -> String {
        if userID == myProfile?.id { return String(localized: "自分") }
        return profilesByID[userID]?.displayName ?? String(localized: "不明")
    }

    // MARK: - 友達 / グループ

    func searchUsers(query: String) async -> [UserProfile] {
        do {
            let results = try await backend.searchUsers(matching: query)
            for profile in results {
                profilesByID[profile.id] = profile
            }
            return results
        } catch {
            banner = AppError.wrap(error)
            return []
        }
    }

    func addFriend(_ profile: UserProfile) async {
        do {
            try await backend.addFriend(profile.id)
            profilesByID[profile.id] = profile
            await refreshFriends()
        } catch {
            banner = AppError.wrap(error)
        }
    }

    func removeFriend(_ profile: UserProfile) async {
        do {
            try await backend.removeFriend(profile.id)
            await refreshFriends()
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// 友達とのチャットを開く(無ければ作る).
    @discardableResult
    func openDirectConversation(with profile: UserProfile) async -> ConversationID? {
        guard profile.canReceiveEncryptedMessages else {
            banner = .recipientHasNoPublicKey(displayName: profile.displayName)
            return nil
        }
        do {
            let conversation = try await backend.openDirectConversation(with: profile.id)
            upsert(conversation)
            selectedConversationID = conversation.id
            await refreshMessages(in: conversation.id)
            await resubscribeForNewConversation()
            return conversation.id
        } catch {
            banner = AppError.wrap(error)
            return nil
        }
    }

    @discardableResult
    func createGroup(name: String, imageData: Data?, members: [UserID]) async -> ConversationID? {
        do {
            let compressed = try await compressedAvatar(imageData)
            let conversation = try await backend.createGroup(
                GroupDraft(name: name, imageData: compressed, memberIDs: members)
            )
            upsert(conversation)
            selectedConversationID = conversation.id
            await refreshConversations()
            await resubscribeForNewConversation()
            return conversation.id
        } catch {
            banner = AppError.wrap(error)
            return nil
        }
    }

    func addMembers(_ userIDs: [UserID], to conversationID: ConversationID) async {
        do {
            let updated = try await backend.addMembers(userIDs, to: conversationID)
            upsert(updated)
            await loadMissingProfiles(for: [updated])
        } catch {
            banner = AppError.wrap(error)
        }
    }

    func leaveConversation(_ conversationID: ConversationID) async {
        do {
            try await backend.leaveConversation(conversationID)
            conversations.removeAll { $0.id == conversationID }
            messagesByConversation.removeValue(forKey: conversationID)
            if selectedConversationID == conversationID {
                selectedConversationID = nil
            }
        } catch {
            banner = AppError.wrap(error)
        }
    }

    private func upsert(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // 一覧の未読数・最終メッセージは維持したまま, メタ情報だけ更新する.
            var merged = conversations[index]
            merged.title = conversation.title ?? merged.title
            merged.imageData = conversation.imageData ?? merged.imageData
            merged.participantIDs = conversation.participantIDs
            conversations[index] = merged
        } else {
            conversations.append(conversation)
            conversations.sort { $0.sortDate > $1.sortDate }
        }
    }

    // MARK: - 内部から使う

    var currentUserID: UserID? { myProfile?.id }

    /// ネットワークに繋がっているか. 送信キューの実行判断と UI 表示に使う.
    var isOnline: Bool { networkMonitor.isOnline }

    func setBanner(_ error: AppError?) {
        banner = error
    }

    /// 送信キューの実行を促す(実装は ChatStore+Messaging).
    func flushOutbox() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.runOutboxFlush()
            self?.flushTask = nil
        }
    }

    var outboxQueue: Outbox { outbox }
    var processor: MediaProcessor { mediaProcessor }
    var files: MediaStore { mediaStore }
}
