import SwiftUI

/// 会社・部署・担当・役職の絞り込み条件(ユーザー一覧・対応依頼などで共通)
struct MemberFilter: Equatable {
    var company = ""     // 空 = すべて
    var department = ""
    var section = ""
    var position = ""

    var isActive: Bool {
        !company.isEmpty || !department.isEmpty || !section.isEmpty || !position.isEmpty
    }

    func matches(_ m: CloudStore.MemberInfo) -> Bool {
        if !company.isEmpty, !m.companies.contains(company) { return false }
        if !department.isEmpty, m.department != department { return false }
        if !section.isEmpty, m.section != section { return false }
        if !position.isEmpty, m.position != position { return false }
        return true
    }
}

/// 会社・部署・担当・役職の絞り込みチップ(横スクロール)。選択肢は pool の実在値から作る
struct MemberFilterBar: View {
    @Binding var filter: MemberFilter
    let pool: [CloudStore.MemberInfo]
    var barBackground = Color(.systemGroupedBackground)

    private var companyOptions: [String] {
        Array(Set(pool.flatMap(\.companies).filter { !$0.isEmpty })).sorted()
    }
    private var departmentOptions: [String] {
        let p = pool.filter { filter.company.isEmpty || $0.companies.contains(filter.company) }
        return Array(Set(p.map(\.department).filter { !$0.isEmpty })).sorted()
    }
    private var sectionOptions: [String] {
        let p = pool.filter {
            (filter.company.isEmpty || $0.companies.contains(filter.company))
                && (filter.department.isEmpty || $0.department == filter.department)
        }
        return Array(Set(p.map(\.section).filter { !$0.isEmpty })).sorted()
    }
    private var positionOptions: [String] {
        let p = pool.filter {
            (filter.company.isEmpty || $0.companies.contains(filter.company))
                && (filter.department.isEmpty || $0.department == filter.department)
                && (filter.section.isEmpty || $0.section == filter.section)
        }
        let existing = Set(p.map(\.position).filter { !$0.isEmpty })
        // 役職は上位から順に表示
        return Positions.all.filter { existing.contains($0) } + existing.subtracting(Positions.all).sorted()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterMenu(title: "会社", selection: $filter.company, options: companyOptions) {
                    // 会社を変えたら下位の絞り込みはリセット
                    filter.department = ""
                    filter.section = ""
                }
                filterMenu(title: "部署", selection: $filter.department, options: departmentOptions) {
                    filter.section = ""
                }
                filterMenu(title: "担当", selection: $filter.section, options: sectionOptions) {}
                filterMenu(title: "役職", selection: $filter.position, options: positionOptions) {}
                if filter.isActive {
                    Button {
                        filter = MemberFilter()
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
        .background(barBackground)
    }

    /// 絞り込みはメニューが完全に閉じてから、アニメーションなしで反映する
    /// (メニューを閉じる動きの最中に一覧が組み変わると表示が大きく崩れるため)
    private func applyFilter(_ change: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { change() }
        }
    }

    private func filterMenu(title: String, selection: Binding<String>,
                            options: [String], onChange: @escaping () -> Void) -> some View {
        Menu {
            Button("すべて") { applyFilter { selection.wrappedValue = ""; onChange() } }
            ForEach(options, id: \.self) { opt in
                Button {
                    applyFilter { selection.wrappedValue = opt; onChange() }
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
                    .frame(maxWidth: 170)
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
        // ラベルの文字数が変わってもMenuが幅を再計算しないため、選択値が変わったら作り直す
        .id("\(title)-\(selection.wrappedValue)")
    }
}

/// ユーザタブ(単体で開く場合のラッパー)
struct MembersView: View {
    var body: some View {
        NavigationStack {
            MembersListCore()
        }
    }
}

/// ユーザー一覧: 財務(BA)のアカウントを表示(どちらの役割からも見られる)
/// 財務は「選択」から複数ユーザを選んでグループトークを組める。
/// BAチャットタブの「ユーザ」切替からも表示される
struct MembersListCore: View {
    @EnvironmentObject var store: CloudStore
    @State private var searchText = ""
    @State private var filter = MemberFilter()
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private var allExperts: [CloudStore.MemberInfo] {
        store.members.filter { $0.role == MemberRole.expert.rawValue }
    }

    private var experts: [CloudStore.MemberInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return allExperts
            .filter {
                filter.matches($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
                    || $0.affiliation.localizedCaseInsensitiveContains(q))
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
            VStack(spacing: 0) {
                MemberFilterBar(filter: $filter, pool: allExperts)
                List {
                    Section("財務(BA) — \(experts.count)人") {
                        ForEach(experts) { member in
                            if selecting {
                                // 選択モード: タップで選択/解除(自分は選べない)。
                                // Buttonだと押下時にグレーになるため、onTapGestureで即時反映する
                                HStack(spacing: 8) {
                                    Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .contentTransition(.identity)
                                        .animation(nil, value: selected)
                                        .foregroundColor(member.id == store.myUid() ? Color(.quaternaryLabel)
                                                         : (selected.contains(member.id) ? Theme.accent : .secondary))
                                    MemberRow(member: member, isMe: member.id == store.myUid())
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard member.id != store.myUid() else { return }
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) {
                                        if selected.contains(member.id) { selected.remove(member.id) }
                                        else { selected.insert(member.id) }
                                    }
                                }
                            } else {
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
            }
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ユーザ名で検索")
            .toolbar {
                if store.isExpert {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if selecting {
                            // 複数選択してグループトークを組む
                            Button {
                                let picked = allExperts.filter { selected.contains($0.id) }
                                guard !picked.isEmpty else { return }
                                let talkId = store.startBaTalk(with: picked)
                                selecting = false
                                selected = []
                                store.activeTab = .baChat
                                store.openBaTalk(talkId)
                            } label: {
                                Text("トーク開始")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(selected.isEmpty)

                            Button {
                                selecting = false
                                selected = []
                            } label: {
                                Image(systemName: "xmark")
                            }
                        } else {
                            Button("選択") { selecting = true }
                        }
                    }
                }
            }
    }
}

/// メンバーのプロフィール(アイコンタップで画面中央にポップアップ表示)
struct MemberProfilePopup: View {
    let member: CloudStore.MemberInfo
    let onClose: () -> Void

    private var roleLabel: String {
        member.role == MemberRole.expert.rawValue ? "財務(BA)" : "担当者(質問者)"
    }

    var body: some View {
        ZStack {
            // 外側タップで閉じる
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 8) {
                AvatarCircleView(iconData: member.iconData,
                                 icon: member.icon,
                                 fallbackBg: member.role == MemberRole.expert.rawValue
                                     ? Theme.accent.opacity(0.8) : Theme.chatBg,
                                 size: 64)
                Text(member.name.isEmpty ? "(名前未設定)" : member.name)
                    .font(.system(size: 17, weight: .semibold))
                Text(roleLabel)
                    .font(.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.tagDoneBg)
                    .foregroundColor(Theme.tagDoneFg)
                    .cornerRadius(8)

                Divider().padding(.vertical, 4)

                VStack(spacing: 6) {
                    if member.companies.isEmpty && member.department.isEmpty && member.section.isEmpty {
                        Text("所属は未設定です").font(.footnote).foregroundColor(.secondary)
                    }
                    ForEach(member.companies, id: \.self) { c in
                        profileRow("会社", c)
                    }
                    if !member.department.isEmpty { profileRow("部署", member.department) }
                    if !member.section.isEmpty { profileRow("担当", member.section) }
                    if !member.position.isEmpty { profileRow("役職", member.position) }
                }
            }
            .padding(24)
            .frame(maxWidth: 300)
            .background(Color(.systemBackground))
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.25), radius: 24)
        }
    }

    private func profileRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
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
