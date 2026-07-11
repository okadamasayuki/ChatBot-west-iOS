import SwiftUI

/// ユーザー一覧: 財務・質問者の全アカウントを表示(どちらの役割からも見られる)
struct MembersView: View {
    @EnvironmentObject var store: CloudStore
    @State private var searchText = ""

    private func matches(_ member: CloudStore.MemberInfo) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || member.name.localizedCaseInsensitiveContains(q)
    }

    private var experts: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.expert.rawValue && matches($0) }
            .sorted { $0.name < $1.name }
    }

    private var questioners: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.questioner.rawValue && matches($0) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("財務(BA) — \(experts.count)人") {
                    ForEach(experts) { member in
                        if store.isExpert, member.id != store.myUid() {
                            // 財務同士はタップでトークを開始できる
                            Button {
                                let talkId = store.startBaTalk(with: [member])
                                store.activeTab = .baChat
                                store.openBaTalk(talkId)
                            } label: {
                                MemberRow(member: member, isMe: false, showsTalkIcon: true)
                            }
                        } else {
                            MemberRow(member: member, isMe: member.id == store.myUid())
                        }
                    }
                }
                Section("担当者(質問者) — \(questioners.count)人") {
                    ForEach(questioners) { member in
                        MemberRow(member: member, isMe: member.id == store.myUid())
                    }
                }
            }
            .navigationTitle("ユーザー一覧")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ユーザー名で検索")
        }
    }
}

struct MemberRow: View {
    let member: CloudStore.MemberInfo
    let isMe: Bool
    var showsTalkIcon = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(member.role == MemberRole.expert.rawValue ? Theme.accent.opacity(0.8) : Theme.chatBg)
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.name.isEmpty ? "(名前未設定)" : member.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    if isMe {
                        Text("自分")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.tagDoneBg)
                            .foregroundColor(Theme.tagDoneFg)
                            .cornerRadius(6)
                    }
                }
            }
            Spacer()
            if showsTalkIcon {
                // タップでトーク開始できることを示す
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.accentDark.opacity(0.7))
            }
        }
        .padding(.vertical, 2)
    }
}
