import SwiftUI

/// すれ違い通信の画面.
///
/// できるのは 2 つだけ.
/// - すれ違い通信を入れる / 切る(既定は切)
/// - すれ違った人の一覧を見て, 友達に追加するかチャットを開く
struct StreetPassView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var busyUserID: UserID?

    private var store: ChatStore { environment.store }
    private var streetPass: StreetPassStore { environment.streetPass }

    var body: some View {
        NavigationStack {
            List {
                switchSection
                if streetPass.isEnabled {
                    cardSection
                    statusSection
                }
                encounterSection
            }
            .navigationTitle("すれ違い通信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
                if !streetPass.encounters.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button(String(localized: "記録をすべて消す"), role: .destructive) {
                                streetPass.removeAll()
                            }
                        } label: {
                            Label(String(localized: "その他"), systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .task {
                // 開いたら「新着」の印を落とす.
                streetPass.markAllSeen()
            }
        }
    }

    // MARK: - 入り切り

    @ViewBuilder
    private var switchSection: some View {
        Section {
            Toggle(String(localized: "すれ違い通信を使う"), isOn: Binding(
                get: { streetPass.isEnabled },
                set: { streetPass.isEnabled = $0 }
            ))
        } footer: {
            Text("""
                入れている間、近くにいる同じアプリの相手と自動で名刺を交換します。\
                渡るのは**あなたの名前・ユーザ ID・下の一言**だけで、メッセージや写真は渡りません。

                サーバーは通らないので、すれ違った記録は双方の端末の中にしか残りません。\
                周りに名前を配りたくないときは切ってください。
                """)
        }
    }

    /// 相手に渡る名刺.
    @ViewBuilder
    private var cardSection: some View {
        Section(String(localized: "あなたの名刺")) {
            LabeledContent(String(localized: "名前")) {
                Text(store.myProfile?.displayName ?? String(localized: "未設定"))
            }
            LabeledContent(String(localized: "ユーザ ID")) {
                Text(store.myProfile.map { "@\($0.handle)" } ?? String(localized: "未設定"))
            }
            TextField(
                String(localized: "一言（任意）"),
                text: Binding(
                    get: { streetPass.comment },
                    set: { streetPass.comment = $0 }
                ),
                axis: .vertical
            )
            .lineLimit(1...3)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent(String(localized: "いまの状態")) {
                Text(statusText)
                    .foregroundStyle(statusIsHealthy ? Palette.subdued : Palette.failure)
            }
            LabeledContent(String(localized: "システムに起こされた回数")) {
                Text(restoreText)
                    .foregroundStyle(Palette.subdued)
            }
            LabeledContent(String(localized: "ロック画面表示")) {
                Text(liveActivityText)
                    .foregroundStyle(Palette.subdued)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("動作状況")
        } footer: {
            Text("""
                アプリを開いている間は数秒で見つかります。\
                閉じている（背面にある）間や、iOS にいったん終了させられた後も、\
                相手が近くに来ればシステムがこのアプリを起こし直します。\
                ただし電池を守るために大きく間引かれるので、数十秒から数分かかることがあります。

                **アプリを上スワイプで終了させたときだけは止まります。** これは iOS の決まりで、\
                アプリ側では変えられません。

                「システムに起こされた回数」は、閉じている間も動いている証拠です。\
                しばらく使っても 0 のままなら、2 台とも Bluetooth が入っているか確かめてください。
                """)
        }
    }

    private var restoreText: String {
        guard let last = streetPass.lastRestoredAt else {
            return String(localized: "\(streetPass.restoreCount) 回")
        }
        return String(localized: "\(streetPass.restoreCount) 回 · 最後は\(DateDisplay.daySeparator(last))")
    }

    /// ロック画面表示(Live Activity)の状況.
    ///
    /// この端末で使えるかどうかは, 推測せずここで確かめられるようにしている.
    /// 使えなくても, すれ違い通信そのものは通常どおり動く.
    private var liveActivityText: String {
        if streetPass.isLiveActivityRunning {
            return String(localized: "出ています")
        }
        if let error = streetPass.liveActivityError {
            return error
        }
        return streetPass.isLiveActivityAvailable
            ? String(localized: "使えます（まだ出ていません）")
            : String(localized: "この端末または設定では使えません")
    }

    private var statusText: String {
        switch streetPass.status {
        case .idle: String(localized: "停止中")
        case .running: String(localized: "探しています")
        case .poweredOff: String(localized: "Bluetooth が切れています")
        case .unauthorized: String(localized: "Bluetooth の使用が許可されていません")
        case .unsupported: String(localized: "この端末では使えません")
        }
    }

    private var statusIsHealthy: Bool {
        streetPass.status == .running || streetPass.status == .idle
    }

    // MARK: - 一覧

    @ViewBuilder
    private var encounterSection: some View {
        if streetPass.encounters.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(String(localized: "まだ誰ともすれ違っていません"), systemImage: "figure.walk.motion")
                } description: {
                    Text("同じアプリを入れた相手と近くにいると、自動で名刺が交換されてここに増えていきます。")
                }
            }
        } else {
            Section(String(localized: "すれ違った人")) {
                ForEach(streetPass.encounters) { encounter in
                    row(encounter)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                streetPass.remove(encounter)
                            } label: {
                                Label(String(localized: "消す"), systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private func row(_ encounter: StreetPassEncounter) -> some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            AvatarView(
                imageData: store.profilesByID[encounter.card.userID]?.avatarData,
                fallbackText: String(encounter.card.displayName.prefix(1)),
                seed: encounter.card.userID.rawValue,
                size: AppConstants.Layout.avatarSmall
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(encounter.card.displayName)
                        .font(.body.weight(.medium))
                    if encounter.isUnseen {
                        Text("新着")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.unreadBadge, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text("@\(encounter.card.handle)")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                if !encounter.card.comment.isEmpty {
                    Text(encounter.card.comment)
                        .font(.footnote)
                        .foregroundStyle(Color.primary)
                }
                Text(subtitle(encounter))
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            }
            Spacer(minLength: 0)
            if busyUserID == encounter.card.userID {
                ProgressView()
            } else {
                Menu {
                    Button {
                        Task { await addFriend(encounter) }
                    } label: {
                        Label(String(localized: "友達に追加"), systemImage: "person.badge.plus")
                    }
                    Button {
                        Task { await openChat(encounter) }
                    } label: {
                        Label(String(localized: "チャットを開く"), systemImage: "bubble.left")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ encounter: StreetPassEncounter) -> String {
        let when = DateDisplay.daySeparator(encounter.lastMetAt)
        return encounter.meetCount > 1
            ? String(localized: "\(when)にすれ違い · 通算 \(encounter.meetCount) 回")
            : String(localized: "\(when)にすれ違い")
    }

    // MARK: - 動作

    private func addFriend(_ encounter: StreetPassEncounter) async {
        busyUserID = encounter.card.userID
        defer { busyUserID = nil }
        guard let profile = await store.resolveProfile(encounter.card.userID) else {
            store.setBanner(.underlying(String(localized: "この人の情報が見つかりませんでした。相手がアプリを開いた後にもう一度試してください")))
            return
        }
        await store.addFriend(profile)
    }

    private func openChat(_ encounter: StreetPassEncounter) async {
        busyUserID = encounter.card.userID
        defer { busyUserID = nil }
        guard let profile = await store.resolveProfile(encounter.card.userID) else {
            store.setBanner(.underlying(String(localized: "この人の情報が見つかりませんでした。相手がアプリを開いた後にもう一度試してください")))
            return
        }
        if await store.openDirectConversation(with: profile) != nil {
            dismiss()
        }
    }
}

#Preview {
    StreetPassView()
        .environment(AppEnvironment.preview())
}
