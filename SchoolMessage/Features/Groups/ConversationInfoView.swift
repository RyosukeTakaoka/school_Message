import SwiftUI

/// チャットの詳細: メンバー一覧・メンバー追加・退出.
struct ConversationInfoView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation

    @State private var isAddingMembers = false
    @State private var selectedNewMemberIDs: Set<UserID> = []
    @State private var isConfirmingLeave = false

    private var store: ChatStore { environment.store }

    private var isOwner: Bool {
        conversation.ownerID == store.currentUserID
    }

    /// まだこのグループにいない友達.
    private var addableFriends: [UserProfile] {
        store.friends.filter { !conversation.participantIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: AppConstants.Layout.standardSpacing) {
                        if let counterpart = store.counterpartProfile(for: conversation) {
                            AvatarView(profile: counterpart, size: AppConstants.Layout.avatarLarge)
                        } else {
                            AvatarView(
                                imageData: conversation.imageData,
                                fallbackText: String(store.title(for: conversation).prefix(1)),
                                seed: conversation.id.rawValue,
                                size: AppConstants.Layout.avatarLarge
                            )
                        }
                        Text(store.title(for: conversation))
                            .font(.title2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppConstants.Layout.standardSpacing)
                    .listRowBackground(Color.clear)
                }

                Section(String(localized: "メンバー(\(conversation.participantIDs.count) 人)")) {
                    ForEach(memberProfiles) { profile in
                        HStack {
                            AvatarView(profile: profile, size: AppConstants.Layout.avatarSmall)
                            VStack(alignment: .leading) {
                                Text(profile.displayName)
                                Text("@\(profile.handle)")
                                    .font(.caption)
                                    .foregroundStyle(Palette.subdued)
                            }
                            Spacer()
                            if profile.id == conversation.ownerID {
                                Text("作成者")
                                    .font(.caption2)
                                    .foregroundStyle(Palette.subdued)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if conversation.kind == .group {
                    if isOwner && !addableFriends.isEmpty {
                        Section {
                            Button(String(localized: "メンバーを追加")) {
                                isAddingMembers = true
                            }
                        }
                    }

                    Section {
                        Button(String(localized: "グループを退出"), role: .destructive) {
                            isConfirmingLeave = true
                        }
                    } footer: {
                        Text("退出すると、このグループの新しいメッセージは届かなくなります。")
                    }
                }
            }
            .navigationTitle("詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .sheet(isPresented: $isAddingMembers) {
                addMembersSheet
            }
            .confirmationDialog(
                String(localized: "このグループを退出しますか?"),
                isPresented: $isConfirmingLeave,
                titleVisibility: .visible
            ) {
                Button(String(localized: "退出する"), role: .destructive) {
                    Task {
                        await store.leaveConversation(conversation.id)
                        dismiss()
                    }
                }
                Button(String(localized: "キャンセル"), role: .cancel) {}
            }
        }
    }

    private var memberProfiles: [UserProfile] {
        store.members(of: conversation)
    }

    private var addMembersSheet: some View {
        NavigationStack {
            List(addableFriends) { friend in
                Button {
                    if selectedNewMemberIDs.contains(friend.id) {
                        selectedNewMemberIDs.remove(friend.id)
                    } else {
                        selectedNewMemberIDs.insert(friend.id)
                    }
                } label: {
                    HStack {
                        AvatarView(profile: friend, size: AppConstants.Layout.avatarSmall)
                        Text(friend.displayName).foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: selectedNewMemberIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedNewMemberIDs.contains(friend.id) ? Color.accentColor : Palette.subdued)
                    }
                }
            }
            .navigationTitle("メンバーを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) {
                        selectedNewMemberIDs = []
                        isAddingMembers = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "追加")) {
                        let ids = Array(selectedNewMemberIDs)
                        selectedNewMemberIDs = []
                        isAddingMembers = false
                        Task { await store.addMembers(ids, to: conversation.id) }
                    }
                    .disabled(selectedNewMemberIDs.isEmpty)
                }
            }
        }
    }
}
