import SwiftUI
import PhotosUI

/// グループ作成.
struct CreateGroupView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var imageData: Data?
    @State private var imagePickerItem: PhotosPickerItem?
    @State private var selectedMemberIDs: Set<UserID> = []
    @State private var isCreating = false
    @State private var isShowingFriends = false

    private var store: ChatStore { environment.store }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedMemberIDs.isEmpty
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: AppConstants.Layout.standardSpacing) {
                        PhotosPicker(selection: $imagePickerItem, matching: .images) {
                            AvatarView(
                                imageData: imageData,
                                fallbackText: name.isEmpty ? "＋" : String(name.prefix(1)),
                                seed: "new-group",
                                size: AppConstants.Layout.avatarLarge
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                            }
                        }
                        // 既定のボタンスタイルのままだと, Form の行全体がこの
                        // ボタンのタップ領域として扱われ, 隣の TextField をタップしても
                        // 写真選択が開いてしまう(名前を確定できない不具合の原因).
                        // `.plain` にしてタップ領域をアバター自身の見た目に限定する.
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "グループ画像を選ぶ"))

                        TextField(String(localized: "グループ名"), text: $name)
                            .font(.title3)
                    }
                    .padding(.vertical, AppConstants.Layout.compactSpacing)
                }

                Section {
                    if store.friends.isEmpty {
                        Text("まだ友達がいません。下のボタンから追加してください。")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    } else {
                        ForEach(store.friends) { friend in
                            memberRow(friend)
                        }
                    }

                    Button {
                        isShowingFriends = true
                    } label: {
                        Label(String(localized: "友達を追加"), systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("メンバー(\(selectedMemberIDs.count) 人を選択中)")
                } footer: {
                    Text("あとからメンバーを追加できるのは、グループを作成した人だけです。")
                }
            }
            .navigationTitle("グループを作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button(String(localized: "作成"), action: create)
                            .disabled(!canCreate)
                    }
                }
            }
            .onChange(of: imagePickerItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    imageData = try? await newValue.loadTransferable(type: Data.self)
                }
            }
            .sheet(isPresented: $isShowingFriends) {
                FriendsView()
            }
            // 作成に失敗したときの理由を必ず画面に出す.
            // これが無いと「作成を押しても何も起きない」ように見えてしまう.
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
            .task { await store.refreshFriends() }
        }
    }

    private func memberRow(_ friend: UserProfile) -> some View {
        Button {
            toggle(friend.id)
        } label: {
            HStack {
                AvatarView(profile: friend, size: AppConstants.Layout.avatarSmall)
                VStack(alignment: .leading) {
                    Text(friend.displayName).foregroundStyle(Color.primary)
                    Text("@\(friend.handle)")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
                Spacer()
                Image(systemName: selectedMemberIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedMemberIDs.contains(friend.id) ? Color.accentColor : Palette.subdued)
            }
        }
        .accessibilityAddTraits(selectedMemberIDs.contains(friend.id) ? [.isSelected] : [])
    }

    private func toggle(_ id: UserID) {
        if selectedMemberIDs.contains(id) {
            selectedMemberIDs.remove(id)
        } else {
            selectedMemberIDs.insert(id)
        }
    }

    private func create() {
        isCreating = true
        Task {
            let created = await store.createGroup(
                name: name,
                imageData: imageData,
                members: Array(selectedMemberIDs)
            )
            isCreating = false
            if created != nil { dismiss() }
        }
    }
}

#Preview {
    CreateGroupView()
        .environment(AppEnvironment.preview())
}
