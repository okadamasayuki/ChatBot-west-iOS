import SwiftUI

/// BAチャット: 財務(BA)同士のトーク。LINEのようにトーク履歴一覧 → 個別トークの構造。
/// 財務アカウント一覧から相手を選んで1:1トーク、複数選択でグループトークを開始できる
struct BaChatView: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        NavigationStack(path: $store.baTalkPath) {
            BaTalkListView()
                .navigationDestination(for: String.self) { _ in
                    BaTalkView()
                }
        }
        .onChange(of: store.baTalkPath) { _ in
            store.handleBaTalkPathChange()
        }
    }
}

// MARK: - トーク履歴一覧

struct BaTalkListView: View {
    @EnvironmentObject var store: CloudStore
    @State private var showNewTalk = false

    private var talks: [BaTalk] {
        var list = store.myBaTalks
        // BA全体トークはまだメッセージが無くても常に一覧の先頭に出す
        if !list.contains(where: { $0.id == "all" }) {
            list.insert(BaTalk(id: "all", name: "BA全体", isGroup: true,
                               lastText: "BA全員のトーク", lastTs: ""), at: 0)
        }
        return list
    }

    var body: some View {
        List(talks) { talk in
            Button {
                store.openBaTalk(talk.id)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Theme.chatBg)
                        Image(systemName: talk.isGroup ? "person.3.fill" : "person.fill")
                            .font(.system(size: talk.isGroup ? 12 : 15))
                            .foregroundColor(.white)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.baTalkName(talk))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
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
        }
        .listStyle(.plain)
        .navigationTitle("BAチャット")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
    }
}

// MARK: - 新規トーク(財務アカウント一覧から相手を選ぶ)

struct NewBaTalkSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = [] // uid
    @State private var groupName = ""

    private var candidates: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.expert.rawValue && $0.id != store.myUid() && !$0.name.isEmpty }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("財務アカウント一覧 — トークする相手を選択") {
                    if candidates.isEmpty {
                        Text("他の財務アカウントがまだありません。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(candidates) { member in
                        Button {
                            if selected.contains(member.id) { selected.remove(member.id) }
                            else { selected.insert(member.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(member.id) ? Theme.accent : .secondary)
                                Text(member.name)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                }

                if selected.count > 1 {
                    Section("グループ名(任意)") {
                        TextField("例: 決算チーム", text: $groupName)
                    }
                }

                Section {
                    Button {
                        let picked = candidates.filter { selected.contains($0.id) }
                        let talkId = store.startBaTalk(with: picked, groupName: groupName)
                        dismiss()
                        store.openBaTalk(talkId)
                    } label: {
                        HStack {
                            Spacer()
                            Text(selected.count > 1 ? "グループトークを開始" : "トークを開始").bold()
                            Spacer()
                        }
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .navigationTitle("新規トーク")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
    @FocusState private var inputFocused: Bool

    private var talk: BaTalk? {
        store.baTalks.first { $0.id == store.currentBaTalkId }
            ?? (store.currentBaTalkId == "all" ? BaTalk(id: "all", name: "BA全体", isGroup: true) : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.baTalkMessages.isEmpty {
                            Text("BA同士の連絡用トークです。\n📎 から相談チャットのリンクを貼れます。")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.header.opacity(0.55))
                                .cornerRadius(10)
                        }
                        ForEach(store.baTalkMessages) { msg in
                            BaMessageBubble(message: msg, isMine: msg.senderUid == store.myUid())
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .background(Theme.chatBg)
                .onChange(of: store.baTalkMessages.last?.id) { id in
                    if let id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onTapGesture { inputFocused = false }
            }

            HStack(alignment: .bottom, spacing: 8) {
                // 相談チャットのリンクを貼る
                Button {
                    showRoomPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.accentDark)
                        .frame(width: 36, height: 42)
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
        .navigationTitle(talk.map { store.baTalkName($0) } ?? "トーク")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRoomPicker) {
            RoomLinkPickerSheet { room in
                store.sendBaTalkMessage(input, roomId: room.id, roomTitle: room.title)
                input = ""
            }
        }
    }
}

/// BAトークのバブル(自分=右・緑、他のBA=左・白+名前)
struct BaMessageBubble: View {
    @EnvironmentObject var store: CloudStore
    let message: BaMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text("👤 \(message.senderName)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.header.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                    }
                    if let roomId = message.roomId {
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
                .background(isMine ? Theme.myBubble : Color(.systemBackground))
                .cornerRadius(14)
                .contextMenu {
                    if !message.text.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("コピー", systemImage: "doc.on.doc")
                        }
                    }
                }
                Text(fmtTime(message.ts))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.header.opacity(0.6))
            }
            if !isMine { Spacer(minLength: 60) }
        }
    }
}

/// リンクとして貼る相談を選ぶシート
struct RoomLinkPickerSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (Room) -> Void

    private var rooms: [Room] {
        store.rooms
            .filter { !$0.lastText.trimmingCharacters(in: .whitespaces).isEmpty }
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
