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
                        // 財務同士は右のトークアイコンをタップするとトークを開始できる
                        MemberRow(member: member,
                                  isMe: member.id == store.myUid(),
                                  onTalk: (store.isExpert && member.id != store.myUid()) ? {
                                      let talkId = store.startBaTalk(with: [member])
                                      store.activeTab = .baChat
                                      store.openBaTalk(talkId)
                                  } : nil)
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
    /// 右のトークアイコンをタップしたときの動作(nilならアイコン非表示)
    var onTalk: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircleView(iconData: member.iconData,
                             icon: member.icon,
                             fallbackBg: member.role == MemberRole.expert.rawValue ? Theme.accent.opacity(0.8) : Theme.chatBg,
                             size: 34)

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
                if !member.department.isEmpty {
                    Text(member.department)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let onTalk {
                // トーク開始はこのアイコンのタップのみ(行全体では開始しない)
                Button(action: onTalk) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.accentDark.opacity(0.8))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
