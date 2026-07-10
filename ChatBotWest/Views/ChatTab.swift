import SwiftUI

/// 質問者/相談一覧タブ: 相談一覧 ⇄ チャット画面
struct ChatTab: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        // 相談を開くとプッシュ遷移(右からスライド・スワイプで戻る)。LINEのトークと同じ動き
        NavigationStack(path: $store.chatPath) {
            RoomListView()
                .navigationDestination(for: String.self) { _ in
                    ChatRoomView()
                }
        }
        .onChange(of: store.chatPath) { _ in
            store.handleChatPathChange()
        }
    }
}

// MARK: - 相談一覧

struct RoomListView: View {
    @EnvironmentObject var store: CloudStore
    @State private var filter: RoomFilter = .mine
    @AppStorage("roomSort") private var sort: String = "new" // "new"=新しい順 / "status"=ステータス順
    @State private var deleteTarget: Room?
    @State private var selectedRooms: Set<String> = [] // 財務: まとめて社内ルール更新する相談の選択
    @State private var showBatchNaiki = false

    enum RoomFilter { case mine, all }

    /// 相談ごとの未回答案件の対応者(nil=案件なし / ""=対応者未決定 / 名前=対応中)。
    /// 複数の案件がある場合は「対応者未決定」を優先して表示する
    private var openCaseHandlers: [String: String] {
        var map: [String: String] = [:]
        for c in store.cases where c.status != .answered {
            if let current = map[c.roomId], current.isEmpty { continue }
            map[c.roomId] = c.handledBy
        }
        return map
    }

    private var visibleRooms: [Room] {
        // メッセージのない相談(空の下書きの残骸)は一覧に出さない
        let base = store.rooms.filter { !$0.lastText.trimmingCharacters(in: .whitespaces).isEmpty }
        let effective: RoomFilter = store.isExpert ? .all : filter
        let list = effective == .mine ? base.filter { store.isMyRoom($0) } : base
        let handlers = openCaseHandlers
        let byNew: (Room, Room) -> Bool = { $0.lastTs > $1.lastTs }
        if sort == "status" {
            // 対応者未決定 → 対応中 → 担当者回答待ち → 完了(同じステータス内は新しい順)
            func rank(_ r: Room) -> Int {
                if r.isDone { return 3 }
                guard let h = handlers[r.id] else { return 2 }
                return h.isEmpty ? 0 : 1
            }
            return list.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : byNew($0, $1) }
        }
        return list.sorted(by: byNew)
    }

    var body: some View {
        List {
            Section {
                sortBar
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

                if visibleRooms.isEmpty {
                    Text(filter == .mine && !store.isExpert
                         ? "あなたの相談はまだありません。\n右上の「＋ 新規」から質問を始めてください。"
                         : "相談はまだありません。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowSeparator(.hidden)
                }

                ForEach(visibleRooms) { room in
                    RoomRowView(room: room,
                                openCaseHandler: openCaseHandlers[room.id],
                                selectable: store.isExpert,
                                selected: selectedRooms.contains(room.id),
                                onToggleSelect: {
                                    if selectedRooms.contains(room.id) { selectedRooms.remove(room.id) }
                                    else { selectedRooms.insert(room.id) }
                                })
                        .contentShape(Rectangle())
                        .onTapGesture { store.openRoom(room.id) }
                        .swipeActions(edge: .trailing) {
                            if store.canDeleteRoom(room) {
                                Button(role: .destructive) {
                                    deleteTarget = room
                                } label: {
                                    Text("削除")
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(store.isExpert ? "相談一覧" : "相談")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.isExpert {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("フィルタ", selection: $filter) {
                        Text("自分の相談").tag(RoomFilter.mine)
                        Text("全員の相談").tag(RoomFilter.all)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.createRoom()
                    } label: {
                        Label("新規", systemImage: "plus")
                    }
                }
            }
        }
        .confirmationDialog("この相談を削除しますか?元に戻せません。",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let room = deleteTarget {
                    Task { await store.deleteRoom(room.id) }
                }
                deleteTarget = nil
            }
            Button("キャンセル", role: .cancel) { deleteTarget = nil }
        }
        .sheet(isPresented: $showBatchNaiki) {
            NaikiUpdateSheet(
                title: selectedRooms.count > 1
                    ? "選択した\(selectedRooms.count)件の相談から社内ルールを更新"
                    : "この相談から社内ルールを更新",
                extract: { try await store.suggestNaikiFromRooms(Array(selectedRooms)) },
                apply: { text in
                    store.appendToNaiki(text)
                    selectedRooms = []
                },
                savedMessage: "✓ 社内ルールに追加しました。全員の回答に反映されます。"
            )
        }
    }

    /// すべての相談が選択済みか
    private var allSelected: Bool {
        !visibleRooms.isEmpty && visibleRooms.allSatisfy { selectedRooms.contains($0.id) }
    }

    /// 並び替えチップ + 財務の全選択・まとめて社内ルール更新ボタン
    private var sortBar: some View {
        HStack(spacing: 6) {
            if store.isExpert && !visibleRooms.isEmpty {
                Button(allSelected ? "全解除" : "全選択") {
                    if allSelected {
                        selectedRooms.removeAll()
                    } else {
                        selectedRooms = Set(visibleRooms.map { $0.id })
                    }
                }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if store.isExpert && !selectedRooms.isEmpty {
                Button {
                    showBatchNaiki = true
                } label: {
                    Text("📋 社内ルールを更新")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
            ForEach([("new", "新しい順"), ("status", "ステータス順")], id: \.0) { key, label in
                Button {
                    sort = key
                } label: {
                    Text(label)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(sort == key ? Theme.accent : Color(.systemBackground))
                        .foregroundColor(sort == key ? .white : .secondary)
                        .overlay(Capsule().stroke(sort == key ? Theme.accent : Color(.separator), lineWidth: 1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RoomRowView: View {
    let room: Room
    /// nil=案件なし / ""=対応者未決定 / 名前=対応中
    let openCaseHandler: String?
    var selectable = false
    var selected = false
    var onToggleSelect: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            if selectable {
                // 財務: 複数の相談を選択してまとめて社内ルールを更新できる
                Button(action: onToggleSelect) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundColor(selected ? Theme.accent : .secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(room.title.isEmpty ? "相談" : room.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(room.isDone ? Color(.tertiaryLabel) : .primary)
                    .lineLimit(1)
                statusTag
            }
            Spacer()
            Text(fmtDate(room.lastTs))
                .font(.system(size: 10))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.vertical, 2)
    }

    // ステータス: 完了 / 対応者未決定 / 〇〇さん対応中 / 担当者回答待ち
    @ViewBuilder
    private var statusTag: some View {
        if room.isDone {
            TagView(text: "✓ 完了", bg: Theme.tagDoneBg, fg: Theme.tagDoneFg)
        } else if let handler = openCaseHandler {
            if handler.isEmpty {
                TagView(text: "対応者未決定",
                        bg: Color(red: 1.0, green: 0xe9 / 255.0, blue: 0xe7 / 255.0),   // 赤系
                        fg: Color(red: 0xc0 / 255.0, green: 0x39 / 255.0, blue: 0x2b / 255.0))
            } else {
                TagView(text: "\(handler)さん対応中",
                        bg: Color(red: 1.0, green: 0xf0 / 255.0, blue: 0xdd / 255.0),   // オレンジ系
                        fg: Color(red: 0xc2 / 255.0, green: 0x6a / 255.0, blue: 0x00 / 255.0))
            }
        } else {
            TagView(text: "担当者回答待ち", bg: Theme.tagWaitingBg, fg: Theme.tagWaitingFg)
        }
    }
}

struct TagView: View {
    let text: String
    let bg: Color
    let fg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg)
            .foregroundColor(fg)
            .cornerRadius(6)
    }
}
