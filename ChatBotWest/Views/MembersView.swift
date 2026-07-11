import SwiftUI

/// ユーザー一覧: 財務(BA)のアカウントを表示(どちらの役割からも見られる)
struct MembersView: View {
    @EnvironmentObject var store: CloudStore
    @State private var searchText = ""
    @State private var filterCompany = ""     // 空 = すべて
    @State private var filterDepartment = ""
    @State private var filterSection = ""

    private func matches(_ member: CloudStore.MemberInfo) -> Bool {
        if !filterCompany.isEmpty, member.company != filterCompany { return false }
        if !filterDepartment.isEmpty, member.department != filterDepartment { return false }
        if !filterSection.isEmpty, member.section != filterSection { return false }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || member.name.localizedCaseInsensitiveContains(q)
            || member.affiliation.localizedCaseInsensitiveContains(q)
    }

    private var allExperts: [CloudStore.MemberInfo] {
        store.members.filter { $0.role == MemberRole.expert.rawValue }
    }

    private var experts: [CloudStore.MemberInfo] {
        allExperts.filter { matches($0) }.sorted { $0.name < $1.name }
    }

    /// 実在するメンバーの値だけを選択肢に出す(会社→部署→担当と上位の絞り込みを反映)
    private var companyOptions: [String] {
        Array(Set(allExperts.map(\.company).filter { !$0.isEmpty })).sorted()
    }
    private var departmentOptions: [String] {
        let pool = allExperts.filter { filterCompany.isEmpty || $0.company == filterCompany }
        return Array(Set(pool.map(\.department).filter { !$0.isEmpty })).sorted()
    }
    private var sectionOptions: [String] {
        let pool = allExperts.filter {
            (filterCompany.isEmpty || $0.company == filterCompany)
                && (filterDepartment.isEmpty || $0.department == filterDepartment)
        }
        return Array(Set(pool.map(\.section).filter { !$0.isEmpty })).sorted()
    }

    private var filterActive: Bool {
        !filterCompany.isEmpty || !filterDepartment.isEmpty || !filterSection.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
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
                }
            }
            .navigationTitle("ユーザー一覧")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ユーザー名で検索")
        }
    }

    /// 会社・部署・担当の絞り込みチップ
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterMenu(title: "会社", selection: $filterCompany, options: companyOptions) {
                    // 会社を変えたら下位の絞り込みはリセット
                    filterDepartment = ""
                    filterSection = ""
                }
                filterMenu(title: "部署", selection: $filterDepartment, options: departmentOptions) {
                    filterSection = ""
                }
                filterMenu(title: "担当", selection: $filterSection, options: sectionOptions) {}
                if filterActive {
                    Button {
                        filterCompany = ""; filterDepartment = ""; filterSection = ""
                    } label: {
                        Label("解除", systemImage: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func filterMenu(title: String, selection: Binding<String>,
                            options: [String], onChange: @escaping () -> Void) -> some View {
        Menu {
            Button("すべて") { selection.wrappedValue = ""; onChange() }
            ForEach(options, id: \.self) { opt in
                Button {
                    selection.wrappedValue = opt
                    onChange()
                } label: {
                    if selection.wrappedValue == opt {
                        Label(opt, systemImage: "checkmark")
                    } else {
                        Text(opt)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.isEmpty ? title : selection.wrappedValue)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selection.wrappedValue.isEmpty ? Color(.secondarySystemGroupedBackground)
                        : Theme.accent.opacity(0.18))
            .foregroundColor(selection.wrappedValue.isEmpty ? .primary : Theme.accentDark)
            .cornerRadius(14)
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
                if !member.affiliation.isEmpty {
                    Text(member.affiliation)
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
