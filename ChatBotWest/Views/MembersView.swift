import SwiftUI

/// ユーザー一覧: 財務・質問者の全アカウントを表示(どちらの役割からも見られる)
struct MembersView: View {
    @EnvironmentObject var store: CloudStore

    private var experts: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.expert.rawValue }
            .sorted { $0.name < $1.name }
    }

    private var questioners: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.questioner.rawValue }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("財務(BA) — \(experts.count)人") {
                    ForEach(experts) { member in
                        MemberRow(member: member, isMe: member.id == store.myUid())
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
        }
    }
}

struct MemberRow: View {
    let member: CloudStore.MemberInfo
    let isMe: Bool

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
        }
        .padding(.vertical, 2)
    }
}
