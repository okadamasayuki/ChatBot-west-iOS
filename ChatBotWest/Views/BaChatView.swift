import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// BAチャット: 財務(BA)同士のトーク。LINEのようにトーク履歴一覧 → 個別トークの構造。
/// 財務アカウント一覧から相手を選んで1:1トーク、複数選択でグループトークを開始できる
struct BaChatView: View {
    @EnvironmentObject var store: CloudStore

    enum Mode { case talks, users }
    @State private var mode: Mode = .talks

    var body: some View {
        NavigationStack(path: $store.baTalkPath) {
            // LINEのタブ切替のように左右にスライドして入れ替わる
            ZStack {
                if mode == .talks {
                    BaTalkListView()
                        .transition(.move(edge: .leading))
                } else {
                    MembersListCore()
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()
            // 切替は常に左上に固定(モードによって位置が動かないように)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 切り替えはアニメーション付きで(急に入れ替わらないように)
                    Picker("表示", selection: $mode.animation(.easeInOut(duration: 0.25))) {
                        Text("トーク").tag(Mode.talks)
                        Text("ユーザ").tag(Mode.users)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 160)
                }
            }
            // 戻りアニメーション中はナビバーを出さず、一覧に戻り切ってから表示する
            .toolbar(store.baTalkPath.isEmpty ? .visible : .hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { value in
                if value.hasPrefix("room:") {
                    // トーク内の相談リンクから開いた相談チャット
                    ChatRoomView()
                } else {
                    BaTalkView()
                }
            }
        }
        // トーク中はタブバーを隠し、一覧に戻った瞬間に表示する
        .toolbar(store.baTalkPath.isEmpty ? .visible : .hidden, for: .tabBar)
        .onChange(of: store.baTalkPath) { _ in
            store.handleBaTalkPathChange()
        }
    }
}

// MARK: - トーク履歴一覧

struct BaTalkListView: View {
    @EnvironmentObject var store: CloudStore
    @State private var showNewTalk = false
    @State private var showSearch = false
    @State private var deleteTarget: BaTalk?

    private var pinnedTalks: [BaTalk] {
        store.myBaTalks.filter { $0.pinnedBy.contains(store.myUid()) }
    }

    private var unpinnedTalks: [BaTalk] {
        store.myBaTalks.filter { !$0.pinnedBy.contains(store.myUid()) }
    }

    var body: some View {
        List {
            if store.myBaTalks.isEmpty {
                Text("トークはまだありません。\n右上のボタンから相手を選んでトークを始めてください。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowSeparator(.hidden)
            }
            // ピン留めしたトーク: 長押しドラッグで並び替えできる
            ForEach(pinnedTalks) { talk in
                talkRow(talk)
            }
            .onMove { from, to in
                store.movePinnedTalks(current: pinnedTalks, from: from, to: to)
            }
            ForEach(unpinnedTalks) { talk in
                talkRow(talk)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 全トーク横断の検索(意味検索対応)
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                Button {
                    showNewTalk = true
                } label: {
                    Label("新規トーク", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showNewTalk) {
            NewBaTalkSheet()
        }
        .sheet(isPresented: $showSearch) {
            BaTalkSearchSheet(scopeTalkId: nil)
        }
        .alert("このトークルームを削除します。\nよろしいですか?",
               isPresented: Binding(get: { deleteTarget != nil },
                                    set: { if !$0 { deleteTarget = nil } })) {
            Button("キャンセル", role: .cancel) { deleteTarget = nil }
            Button("削除", role: .destructive) {
                if let talk = deleteTarget {
                    Task { await store.deleteBaTalk(talk.id) }
                }
                deleteTarget = nil
            }
        }
    }

    /// トーク一覧の1行(タップで開く。左スライド=削除 / 右スライド=ピン留め)
    @ViewBuilder
    private func talkRow(_ talk: BaTalk) -> some View {
        SwipeDeleteRow(onDelete: { deleteTarget = talk },
                       leadingIcon: talk.pinnedBy.contains(store.myUid()) ? "pin.slash.fill" : "pin.fill",
                       onLeading: { store.toggleBaTalkPin(talk.id) },
                       contentInsets: EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)) {
        // タップで開く(スライド中は開かないよう、ButtonではなくonTapGestureにする)
        Group {
            HStack(spacing: 10) {
                // 1:1は相手のアイコン、メモはノート、グループは人型
                if !talk.isGroup, talk.memberUids.count == 2,
                   let partnerUid = talk.memberUids.first(where: { $0 != store.myUid() }),
                   let partner = store.member(partnerUid) {
                    AvatarCircleView(iconData: partner.iconData, icon: partner.icon, size: 48)
                } else {
                    ZStack {
                        Circle().fill(Theme.chatBg)
                        Image(systemName: talk.memberUids.count <= 1 ? "note.text" : (talk.isGroup ? "person.3.fill" : "person.fill"))
                            .font(.system(size: talk.isGroup ? 15 : 19))
                            .foregroundColor(.white)
                    }
                    .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(store.baTalkName(talk))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if talk.pinnedBy.contains(store.myUid()) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                    Text(snippet(talk.lastText, 40).isEmpty ? "(メッセージなし)" : snippet(talk.lastText, 40))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !talk.lastTs.isEmpty {
                    Text(fmtDate(talk.lastTs))
                        .font(.system(size: 10))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
            .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openBaTalk(talk.id) }
        }
        // 区切り線を全行とも左端から表示(行によって途切れて見えないように)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

/// 選択中のメンバーを上部の枠にチップで表示(タップで解除)
struct SelectedMembersRow: View {
    let members: [CloudStore.MemberInfo]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(members) { m in
                    Button {
                        onRemove(m.id)
                    } label: {
                        HStack(spacing: 4) {
                            AvatarCircleView(iconData: m.iconData, icon: m.icon, size: 20)
                            Text(m.name).font(.system(size: 12))
                                .foregroundColor(.primary)
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.15))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - 新規トーク(財務アカウント一覧から相手を選ぶ)

struct NewBaTalkSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = [] // uid
    @State private var groupName = ""
    @State private var searchText = ""
    @State private var filter = MemberFilter()

    private var pool: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.expert.rawValue && $0.id != store.myUid() && !$0.name.isEmpty }
    }

    private var candidates: [CloudStore.MemberInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return pool
            .filter {
                filter.matches($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
                    || $0.affiliation.localizedCaseInsensitiveContains(q))
            }
            .sorted { $0.name < $1.name }
    }

    /// 表示中(絞り込み後)の全員が選択済みか
    private var allShownSelected: Bool {
        !candidates.isEmpty && Set(candidates.map(\.id)).isSubset(of: selected)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            Form {
                Section("選択中 — \(selected.count)人") {
                    if selected.isEmpty {
                        Text("メモ作成可")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        SelectedMembersRow(members: pool.filter { selected.contains($0.id) }) { uid in
                            selected.remove(uid)
                        }
                    }
                }

                Section("ルーム名") {
                    TextField("例: 決算チーム", text: $groupName)
                }

                // 検索・絞り込みはメンバー選択の真上に置く
                Section {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("ユーザ名で検索", text: $searchText)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        Divider().padding(.leading, 16)
                        MemberFilterBar(filter: $filter, pool: pool,
                                        barBackground: Color(.secondarySystemGroupedBackground))
                    }
                    .listRowInsets(EdgeInsets())
                }

                Section("ユーザ選択") {
                    if candidates.isEmpty {
                        Text("該当する財務アカウントがありません。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if !candidates.isEmpty, filter.isActive || !searchText.isEmpty {
                        // 担当・部署などで絞り込んで、その単位でまとめて追加できる
                        Button {
                            let ids = Set(candidates.map(\.id))
                            if allShownSelected { selected.subtract(ids) }
                            else { selected.formUnion(ids) }
                        } label: {
                            HStack {
                                Image(systemName: allShownSelected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(allShownSelected ? Theme.accent : .secondary)
                                Text("表示中の\(candidates.count)人をまとめて選択")
                                    .foregroundColor(Theme.accentDark)
                                Spacer()
                            }
                        }
                    }
                    ForEach(candidates) { member in
                        Button {
                            if selected.contains(member.id) { selected.remove(member.id) }
                            else { selected.insert(member.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(member.id) ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.name)
                                        .foregroundColor(.primary)
                                    if !member.affiliation.isEmpty {
                                        Text(member.affiliation)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }

            }
            }
            .navigationTitle("新規トーク")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 開始とキャンセルは別々の枠のボタンで表示
                    Button {
                        // 絞り込みを変えても選択は保持されるよう、全体から選ぶ
                        let picked = pool.filter { selected.contains($0.id) }
                        let talkId = store.startBaTalk(with: picked, groupName: groupName)
                        dismiss()
                        store.openBaTalk(talkId)
                    } label: {
                        // 誰も選択していなければ自分だけのトーク(メモ)として開始できる
                        Text("開始")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 個別トーク

struct BaTalkView: View {
    @EnvironmentObject var store: CloudStore
    @State private var input = ""
    @State private var showRoomPicker = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photosItem: PhotosPickerItem?
    @State private var attachError: String?
    @State private var showAddMembers = false
    @State private var showMembers = false
    @State private var profileMember: CloudStore.MemberInfo?
    @State private var showSearch = false
    @FocusState private var inputFocused: Bool

    private var talk: BaTalk? {
        store.baTalks.first { $0.id == store.currentBaTalkId }
    }

    /// 入力中の「@…」部分(空白が入るまでをクエリとする)
    private var mentionQuery: String? {
        guard let atIdx = input.lastIndex(of: "@") else { return nil }
        let after = String(input[input.index(after: atIdx)...])
        if after.contains(" ") || after.contains("\n") || after.contains("　") { return nil }
        return after
    }

    /// メンション候補(トークのメンバーから自分を除く)
    private var mentionCandidates: [String] {
        guard let q = mentionQuery, let t = talk else { return [] }
        let names = t.memberNames.filter { $0 != store.myName() && !$0.isEmpty }
        return q.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    /// 入力中の「@…」を「@名前 」に置き換える
    private func insertMention(_ name: String) {
        guard let atIdx = input.lastIndex(of: "@") else { return }
        input = String(input[..<atIdx]) + "@\(name) "
    }

    /// 表示するメッセージ(後から追加されたメンバーには追加時点以降だけ見せる)
    private var visibleMessages: [BaMessage] {
        guard let t = talk, let from = t.historyFrom[store.myUid()] else { return store.baTalkMessages }
        return store.baTalkMessages.filter { $0.ts >= from }
    }

    /// 自分のメッセージの既読状況(1:1は既読/未読、グループは既読数。メモでは表示しない)
    private func readStatus(for msg: BaMessage) -> String? {
        guard let t = talk, t.memberUids.count > 1, msg.senderUid == store.myUid() else { return nil }
        let readers = t.reads.filter { $0.key != store.myUid() && $0.value >= msg.ts }.count
        if t.isGroup {
            return readers > 0 ? "既読\(readers)" : "未読"
        }
        return readers > 0 ? "既読" : "未読"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleMessages) { msg in
                            BaMessageBubble(onAvatarTap: { m in profileMember = m },
                                            message: msg,
                                            isMine: msg.senderUid == store.myUid(),
                                            readStatus: readStatus(for: msg),
                                            mentionNames: talk?.memberNames ?? [])
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .background(Theme.chatBg)
                .onChange(of: visibleMessages.last?.id) { id in
                    if let id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onTapGesture { inputFocused = false }
            }

            // @メンションの候補(入力中の「@…」に応じて表示。タップで挿入)
            if !mentionCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionCandidates, id: \.self) { name in
                            Button("@\(name)") {
                                insertMention(name)
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.tagWaitingBg)
                            .foregroundColor(Theme.tagWaitingFg)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.top, 6)
                .background(Color(.secondarySystemBackground))
            }

            HStack(alignment: .bottom, spacing: 8) {
                // 添付(相談リンク・写真・ファイル)
                Menu {
                    Button {
                        showRoomPicker = true
                    } label: {
                        Label("相談チャット", systemImage: "link")
                    }
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("写真", systemImage: "photo")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("ファイル", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.accentDark)
                        .frame(width: 32, height: 42)
                }

                TextField("メッセージを入力...", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.systemBackground))
                    .cornerRadius(18)
                    .focused($inputFocused)

                Button {
                    store.sendBaTalkMessage(input)
                    input = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Theme.accent.opacity(0.4) : Theme.accent)
                        .clipShape(Circle())
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
        }
        .navigationBarTitleDisplayMode(.inline)
        // 戻るボタンは出さない(BAチャットタブの再タップ・左端スワイプで戻る)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // タイトル部分。どのトークもタップでルーム名を変更できる
            // (メンバー名の羅列が長いときは省略して右上のボタンに重ならないようにする)
            ToolbarItem(placement: .principal) {
                if let t = talk {
                    Button {
                        renameText = t.name
                        showRename = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.baTalkName(t))
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 160)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "pencil")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("トーク")
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // トーク内検索(意味検索対応)
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                // メンバー一覧
                Button {
                    showMembers = true
                } label: {
                    Image(systemName: "person.3")
                }
                // メンバー追加
                Button {
                    showAddMembers = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showAddMembers) {
            if let t = talk {
                AddBaMembersSheet(talk: t)
            }
        }
        .sheet(isPresented: $showMembers) {
            if let t = talk {
                BaTalkMembersSheet(talk: t)
            }
        }
        .overlay {
            // アイコンタップのプロフィール(画面中央のポップアップ)
            if let m = profileMember {
                MemberProfilePopup(member: m) { profileMember = nil }
            }
        }
        .sheet(isPresented: $showSearch) {
            BaTalkSearchSheet(scopeTalkId: store.currentBaTalkId)
        }
        .alert("ルーム名を設定", isPresented: $showRename) {
            TextField("例: 決算チーム", text: $renameText)
            Button("保存") {
                if let t = talk {
                    store.renameBaTalk(t.id, name: renameText)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("空にすると相手の名前・メンバー名が表示されます。")
        }
        .sheet(isPresented: $showRoomPicker) {
            RoomLinkPickerSheet { room in
                store.sendBaTalkMessage(input, roomId: room.id, roomTitle: room.title)
                input = ""
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photosItem, matching: .images)
        .onChange(of: photosItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    if let jpeg = AttachmentUtils.compressImage(data) {
                        store.sendBaTalkMessage("", attachmentData: jpeg, attachmentName: "photo.jpg", attachmentType: "image")
                    } else {
                        attachError = "写真を圧縮できませんでした。"
                    }
                }
                photosItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                attachError = "ファイルを読み込めませんでした。"
                return
            }
            guard data.count <= AttachmentUtils.maxBytes else {
                attachError = "ファイルが大きすぎます(600KBまで)。"
                return
            }
            store.sendBaTalkMessage("", attachmentData: data, attachmentName: url.lastPathComponent, attachmentType: "file")
        }
        .alert("添付エラー", isPresented: Binding(get: { attachError != nil },
                                              set: { if !$0 { attachError = nil } })) {
            Button("OK") { attachError = nil }
        } message: {
            Text(attachError ?? "")
        }
    }
}

// MARK: - メンバー追加(履歴を見せるか選択できる)

/// トークの参加メンバー一覧。行をタップするとプロフィールが見られる
struct BaTalkMembersSheet: View {
    @EnvironmentObject var store: CloudStore
    let talk: BaTalk
    @Environment(\.dismiss) private var dismiss
    @State private var profileMember: CloudStore.MemberInfo?

    private var members: [CloudStore.MemberInfo] {
        talk.memberUids.enumerated().map { i, uid in
            store.member(uid) ?? CloudStore.MemberInfo(
                id: uid,
                name: i < talk.memberNames.count ? talk.memberNames[i] : "(退会済み)",
                role: MemberRole.expert.rawValue)
        }
        .filter { $0.id != store.myUid() } // 自分は表示しない
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("メンバー — \(members.count)人") {
                    ForEach(members) { m in
                        Button {
                            profileMember = m
                        } label: {
                            MemberRow(member: m, isMe: m.id == store.myUid())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("メンバー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .overlay {
                if let m = profileMember {
                    MemberProfilePopup(member: m) { profileMember = nil }
                }
            }
        }
    }
}

struct AddBaMembersSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let talk: BaTalk
    @State private var selected: Set<String> = []
    @State private var showHistory = true
    @State private var searchText = ""
    @State private var filter = MemberFilter()

    private var pool: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.expert.rawValue && !talk.memberUids.contains($0.id) && !$0.name.isEmpty }
    }

    private var candidates: [CloudStore.MemberInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return pool
            .filter {
                filter.matches($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
                    || $0.affiliation.localizedCaseInsensitiveContains(q))
            }
            .sorted { $0.name < $1.name }
    }

    /// 表示中(絞り込み後)の全員が選択済みか
    private var allShownSelected: Bool {
        !candidates.isEmpty && Set(candidates.map(\.id)).isSubset(of: selected)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            Form {
                if !selected.isEmpty {
                    Section("選択中 — \(selected.count)人") {
                        SelectedMembersRow(members: pool.filter { selected.contains($0.id) }) { uid in
                            selected.remove(uid)
                        }
                    }
                }

                // ユーザー数が多くてもスクロールせずに済むよう、操作は一覧の上に置く
                Section {
                    Toggle("過去の履歴も見せる", isOn: $showHistory)
                        .tint(Theme.accent)
                }

                // 検索・絞り込みはメンバー選択の真上に置く
                Section {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("ユーザ名で検索", text: $searchText)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        Divider().padding(.leading, 16)
                        MemberFilterBar(filter: $filter, pool: pool,
                                        barBackground: Color(.secondarySystemGroupedBackground))
                    }
                    .listRowInsets(EdgeInsets())
                }

                Section("メンバー選択") {
                    if candidates.isEmpty {
                        Text("追加できるメンバーがいません。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if !candidates.isEmpty, filter.isActive || !searchText.isEmpty {
                        // 担当・部署などで絞り込んで、その単位でまとめて追加できる
                        Button {
                            let ids = Set(candidates.map(\.id))
                            if allShownSelected { selected.subtract(ids) }
                            else { selected.formUnion(ids) }
                        } label: {
                            HStack {
                                Image(systemName: allShownSelected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(allShownSelected ? Theme.accent : .secondary)
                                Text("表示中の\(candidates.count)人をまとめて選択")
                                    .foregroundColor(Theme.accentDark)
                                Spacer()
                            }
                        }
                    }
                    ForEach(candidates) { member in
                        Button {
                            if selected.contains(member.id) { selected.remove(member.id) }
                            else { selected.insert(member.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(member.id) ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.name)
                                        .foregroundColor(.primary)
                                    if !member.affiliation.isEmpty {
                                        Text(member.affiliation)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }

            }
            }
            .navigationTitle("メンバー追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 追加するとキャンセルは別々の枠のボタンで表示
                    Button {
                        // 絞り込みを変えても選択は保持されるよう、全体から選ぶ
                        let picked = pool.filter { selected.contains($0.id) }
                        store.addBaTalkMembers(talk.id, members: picked, showHistory: showHistory)
                        dismiss()
                    } label: {
                        Text(selected.count > 1 ? "追加する(\(selected.count)人)" : "追加する")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(selected.isEmpty)

                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}

// MARK: - トーク検索(キーワード+意味検索)

struct BaTalkSearchSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    /// nil = 全トーク横断 / 指定 = そのトーク内のみ
    let scopeTalkId: String?
    @State private var query = ""
    @State private var busy = false
    @State private var searched = false
    @State private var results: [CloudStore.BaSearchResult] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("検索ワード(意味が近いものも見つかります)", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button("検索") { search() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)

                if busy {
                    Spacer()
                    ProgressView("検索中…(AIが意味の近いメッセージも探しています)")
                        .font(.footnote)
                    Spacer()
                } else if searched && results.isEmpty {
                    Spacer()
                    Text("見つかりませんでした。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(results) { r in
                        Button {
                            dismiss()
                            if scopeTalkId == nil {
                                store.openBaTalk(r.talkId)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(r.talkName)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(fmtDate(r.ts))
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                Text("\(r.senderName): \(r.text)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(scopeTalkId == nil ? "BAチャットを検索" : "このトークを検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true
        Task {
            results = (try? await store.searchBaTalks(query: q, in: scopeTalkId)) ?? []
            searched = true
            busy = false
        }
    }
}

/// BAトークのバブル(自分=右・緑、他のBA=左・白+名前)
struct BaMessageBubble: View {
    @EnvironmentObject var store: CloudStore
    var onAvatarTap: ((CloudStore.MemberInfo) -> Void)? = nil
    let message: BaMessage
    let isMine: Bool
    var readStatus: String? = nil
    var mentionNames: [String] = []
    @State private var showEdit = false

    var body: some View {
        // メンバー追加などのシステム通知は中央に表示
        if message.senderUid == "system" {
            Text(message.text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.header.opacity(0.55))
                .cornerRadius(10)
                .frame(maxWidth: .infinity)
        } else {
            bubbleBody
        }
    }

    private var bubbleBody: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 60) }
            if !isMine {
                // 相手のアイコン(タップでプロフィール)
                let m = store.member(message.senderUid)
                AvatarCircleView(iconData: m?.iconData ?? "",
                                 icon: m?.icon ?? "",
                                 size: 34)
                    .onTapGesture { if let m { onAvatarTap?(m) } }
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                // 名前ラベルの横に時刻を表示
                HStack(spacing: 6) {
                    if !isMine {
                        Text(message.senderName)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.header.opacity(0.8))
                    }
                    Text(fmtTime(message.ts))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.header.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.deleted ? AttributedString(message.text) : Self.highlightMentions(message.text, names: mentionNames))
                            .font(.system(size: 14))
                            .italic(message.deleted)
                            .foregroundColor(message.deleted ? .secondary : .primary)
                            .lineSpacing(4)
                    }
                    if !message.deleted, let type = message.attachmentType, let data = message.attachmentData {
                        AttachmentContentView(type: type, name: message.attachmentName ?? "", dataB64: data)
                    }
                    if !message.deleted, let roomId = message.roomId {
                        // 相談チャットへのリンクカード(タップで開く)
                        Button {
                            store.openRoomFromBaChat(roomId)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.tagWaitingFg)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(message.roomTitle?.isEmpty == false ? message.roomTitle! : "相談")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Theme.tagWaitingFg)
                                        .lineLimit(1)
                                    Text("タップして相談を開く")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Theme.tagWaitingBg)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(LineBubbleShape(isMine: isMine).fill(isMine ? Theme.myBubble : Color(.systemBackground)))
                // Teams風: リアクションはバブルの下角に重ねて表示。
                // 時刻の位置が動かないよう、余白は増やさず重ねるだけにする
                .overlay(alignment: isMine ? .bottomLeading : .bottomTrailing) {
                    if !message.reactions.isEmpty, !message.deleted {
                        ReactionChipsView(reactions: message.reactions, myUid: store.myUid(),
                                          nameFor: { uid in store.member(uid)?.name ?? "" }) { emoji in
                            store.toggleBaReaction(message, emoji: emoji)
                        }
                        .offset(x: isMine ? -4 : 4, y: 9)
                    }
                }
                .contextMenu {
                    if !message.deleted {
                        // 1列目: リアクション絵文字を1行に横並び
                        if #available(iOS 17.0, *) {
                            ControlGroup {
                                ForEach(CloudStore.reactionEmojis, id: \.self) { emoji in
                                    Button(emoji) {
                                        store.toggleBaReaction(message, emoji: emoji)
                                    }
                                }
                            }
                            .controlGroupStyle(.palette)
                        } else {
                            ControlGroup {
                                ForEach(CloudStore.reactionEmojis, id: \.self) { emoji in
                                    Button(emoji) {
                                        store.toggleBaReaction(message, emoji: emoji)
                                    }
                                }
                            }
                            .controlGroupStyle(.compactMenu)
                        }
                        if !message.text.isEmpty {
                            Button {
                                UIPasteboard.general.string = message.text
                            } label: {
                                Label("コピー", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    if isMine {
                        if message.deleted {
                            Button {
                                store.restoreBaMessage(message)
                            } label: {
                                Label("元に戻す", systemImage: "arrow.uturn.backward")
                            }
                        } else {
                            if !message.text.isEmpty {
                                Button {
                                    showEdit = true
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                            }
                            Button(role: .destructive) {
                                store.deleteBaMessage(message)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showEdit) {
                    EditMessageSheet(initialText: message.text) { newText in
                        store.updateBaMessageText(message, newText: newText)
                    }
                }
                // 未読・既読はメッセージの下に表示
                if isMine, let readStatus {
                    Text(readStatus)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.header.opacity(0.6))
                }
            }
            if !isMine { Spacer(minLength: 60) }
        }
    }

    /// 「@名前」をハイライトする
    static func highlightMentions(_ text: String, names: [String]) -> AttributedString {
        var attr = AttributedString(text)
        for name in names where !name.isEmpty {
            let needle = "@\(name)"
            var searchIdx = text.startIndex
            while let r = text.range(of: needle, range: searchIdx..<text.endIndex) {
                if let lower = AttributedString.Index(r.lowerBound, within: attr),
                   let upper = AttributedString.Index(r.upperBound, within: attr) {
                    attr[lower..<upper].foregroundColor = Theme.tagWaitingFg
                    attr[lower..<upper].font = .system(size: 14, weight: .semibold)
                }
                searchIdx = r.upperBound
            }
        }
        return attr
    }
}

/// リンクとして貼る相談を選ぶシート
struct RoomLinkPickerSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (Room) -> Void

    private var rooms: [Room] {
        // 完了した相談はリンクの選択肢に出さない
        store.rooms
            .filter { !$0.lastText.trimmingCharacters(in: .whitespaces).isEmpty && !$0.isDone }
            .sorted { $0.lastTs > $1.lastTs }
    }

    var body: some View {
        NavigationStack {
            List(rooms) { room in
                Button {
                    onPick(room)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.title.isEmpty ? "相談" : room.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if room.isDone {
                                TagView(text: "✓ 完了", bg: Theme.tagDoneBg, fg: Theme.tagDoneFg)
                            }
                            Text(fmtDate(room.lastTs))
                                .font(.system(size: 10))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("リンクする相談を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}
