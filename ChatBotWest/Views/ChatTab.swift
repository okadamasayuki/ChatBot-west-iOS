import SwiftUI

/// 質問者/相談一覧タブ: 相談一覧 ⇄ チャット画面
struct ChatTab: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        // 相談を開くとプッシュ遷移(右からスライド・スワイプで戻る)。LINEのトークと同じ動き
        NavigationStack(path: $store.chatPath) {
            RoomListView()
                // 戻りアニメーション中はフィルタ(ナビバー)を出さず、一覧に戻り切ってから表示する
                .toolbar(store.chatPath.isEmpty ? .visible : .hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { _ in
                    ChatRoomView()
                }
        }
        // チャット中はタブバーを隠し、一覧に戻った瞬間に表示する
        .toolbar(store.chatPath.isEmpty ? .visible : .hidden, for: .tabBar)
        .onChange(of: store.chatPath) { _ in
            store.handleChatPathChange()
        }
    }
}

// MARK: - 相談一覧

struct RoomListView: View {
    @EnvironmentObject var store: CloudStore
    @State private var filter: RoomFilter = .mine
    @State private var expertFilter: ExpertFilter = .all // 財務: すべて / 自分が対応中
    @AppStorage("roomSort") private var sort: String = "new" // "new"=新しい順 / "status"=ステータス順
    @AppStorage("hideDone") private var hideDone = false     // 完了した相談を一覧に出さない
    @State private var deleteTarget: Room?
    @State private var selectedRooms: Set<String> = [] // 財務: まとめて社内ルール更新する相談の選択
    @State private var showBatchNaiki = false

    enum RoomFilter { case mine, all }
    enum ExpertFilter { case all, handling }

    /// 未回答案件のある相談の集合
    private var openCaseRoomIds: Set<String> {
        Set(store.cases.filter { $0.status != .answered }.map { $0.roomId })
    }

    private var visibleRooms: [Room] {
        // メッセージのない相談(空の下書きの残骸)は一覧に出さない
        let base = store.rooms.filter { !$0.lastText.trimmingCharacters(in: .whitespaces).isEmpty }
        let effective: RoomFilter = store.isExpert ? .all : filter
        var list = effective == .mine ? base.filter { store.isMyRoom($0) } : base
        // 財務: 「自分が対応中」=
        //  ① 未回答案件の対応者が自分の相談
        //  ② 最新のBA回答が自分で、いま担当者回答待ち(未回答案件なし・未完了)の相談
        if store.isExpert, expertFilter == .handling {
            let me = store.myName()
            let handlingRoomIds = Set(store.cases
                .filter { $0.status != .answered && $0.handledBy == me }
                .map { $0.roomId })
            // 相談ごとの最新の回答済み案件の対応者が自分か
            var latest: [String: (ts: String, mine: Bool)] = [:]
            for c in store.cases where c.status == .answered {
                let ts = c.answeredAt ?? c.askedAt
                if let cur = latest[c.roomId], cur.ts > ts { continue }
                latest[c.roomId] = (ts, c.handledBy == me)
            }
            let openRoomIds = Set(store.cases.filter { $0.status != .answered }.map { $0.roomId })
            list = list.filter { room in
                if room.handler == me { return true } // 相談の担当BAが自分(完了した相談も含む)
                if handlingRoomIds.contains(room.id) { return true }
                // 最新のBA回答が自分の相談(完了済みも含む。他のBAが対応中のものは除く)
                return !openRoomIds.contains(room.id) && (latest[room.id]?.mine ?? false)
            }
        }
        if hideDone {
            list = list.filter { !$0.isDone }
        }
        let openIds = openCaseRoomIds
        let byNew: (Room, Room) -> Bool = { $0.lastTs > $1.lastTs }
        if sort == "status" {
            // 対応者未決定 → 対応中 → 担当者回答待ち → 完了(同じステータス内は新しい順)
            func rank(_ r: Room) -> Int {
                if r.isDone { return 3 }
                guard openIds.contains(r.id) else { return 2 }
                return effectiveHandler(r).isEmpty ? 0 : 1
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
                    Text(store.isExpert && expertFilter == .handling
                         ? "自分が対応中の相談はありません。"
                         : filter == .mine && !store.isExpert
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
                                // ステータスタグも「担当:」と同じ統一ロジック(effectiveHandler)で表示
                                openCaseHandler: openCaseRoomIds.contains(room.id) ? effectiveHandler(room) : nil,
                                handlerName: effectiveHandler(room),
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
        // タイトル表記は出さず、フィルタを中央に置く
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.isExpert {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("フィルタ", selection: $expertFilter) {
                        Text("すべて").tag(ExpertFilter.all)
                        Text("担当中").tag(ExpertFilter.handling)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 160)
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("フィルタ", selection: $filter) {
                        Text("自分の相談").tag(RoomFilter.mine)
                        Text("全員の相談").tag(RoomFilter.all)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 160)
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
        .alert("この相談を削除します。\nよろしいですか?",
               isPresented: Binding(get: { deleteTarget != nil },
                                    set: { if !$0 { deleteTarget = nil } })) {
            Button("キャンセル", role: .cancel) { deleteTarget = nil }
            Button("削除", role: .destructive) {
                if let room = deleteTarget {
                    Task { await store.deleteRoom(room.id) }
                }
                deleteTarget = nil
            }
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

    /// 相談の担当BA(rooms.handler が唯一の真実。案件由来の担当はバックフィルで書き戻される。
    /// 書き戻しの反映待ちの間だけ案件から推定した値で補完する)
    private func effectiveHandler(_ room: Room) -> String {
        room.handler.isEmpty ? store.derivedHandler(roomId: room.id) : room.handler
    }

    /// 並び替え・フィルタ用のチップ
    private func sortChip(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Theme.accent : Color(.systemBackground))
            .foregroundColor(active ? .white : .secondary)
            .overlay(Capsule().stroke(active ? Theme.accent : Color(.separator), lineWidth: 1))
            .clipShape(Capsule())
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
                    sortChip(label, active: sort == key)
                }
                .buttonStyle(.plain)
            }
            Button {
                hideDone.toggle()
            } label: {
                sortChip("完了を非表示", active: hideDone)
            }
            .buttonStyle(.plain)
        }
    }
}

struct RoomRowView: View {
    let room: Room
    /// nil=案件なし / ""=対応者未決定 / 名前=対応中
    let openCaseHandler: String?
    /// この相談の実質的な担当BA(空=未定)
    var handlerName: String = ""
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
                HStack(spacing: 6) {
                    statusTag
                    if selectable {
                        // 財務には各相談の担当BAを常に表示
                        Text("担当: \(handlerName.isEmpty ? "未定" : handlerName)")
                            .font(.system(size: 10))
                            .foregroundColor(handlerName.isEmpty ? Color(red: 0xc0 / 255.0, green: 0x39 / 255.0, blue: 0x2b / 255.0) : Color(.secondaryLabel))
                    }
                }
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
                TagView(text: "BA回答待ち",
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
