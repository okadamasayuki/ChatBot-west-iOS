import Foundation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore

enum AppTab: Hashable {
    case chat, expert, naiki, manual, settings
}

/// Firebase(Auth / Firestore)との同期と、アプリの状態を一元管理する。
/// Web版と同一のデータ構造 `workspaces/{wid}/…` を読み書きするため、
/// Web版・iOS版どちらからでも同じ相談・案件・社内ルールが見える。
@MainActor
final class CloudStore: ObservableObject {

    // MARK: - 認証・アカウント
    @Published var user: User?
    @Published var role: MemberRole?
    @Published var nickname: String = ""
    @Published var answerStyle: String = ""
    @Published var authReady = false
    var pendingRole: MemberRole = .questioner   // 新規登録時に使う
    var pendingNickname: String = ""

    // MARK: - 共有データ
    @Published var naiki: String = Prompts.defaultNaiki
    @Published var rooms: [Room] = []
    @Published var cases: [CaseItem] = []
    @Published var qaLog: [QaEntry] = []
    @Published var manuals: [Manual] = []

    // MARK: - 画面状態
    @Published var activeTab: AppTab = .chat
    @Published var highlightCaseId: String?   // BAタブでハイライトする案件(チャットからのジャンプ)
    @Published var chatPath: [String] = []    // NavigationStack のパス(相談を開くとプッシュ遷移)
    @Published var currentRoomId: String?
    @Published var roomMessages: [Message] = []
    @Published var pendingTyping = false
    @Published var sending = false
    var pendingRoom: Room? // 未送信の新規相談(最初のメッセージ送信まで保存しない)

    /// 開発モード: APIが担当者役(会計の素人)になり、聞き返しへの返答や回答への更問を自動で行う
    @Published var devMode: Bool = UserDefaults.standard.bool(forKey: "devMode") {
        didSet {
            UserDefaults.standard.set(devMode, forKey: "devMode")
            if devMode {
                // オンにし直したら状態をリセットして、開いている相談を即再判定する
                devFollowupCounts = [:]
                devClarifyCounts = [:]
                devRepliedMsgIds = []
                devMaybeReply()
            }
        }
    }
    private let devReplyLimit = 5 // 開発モードの返信上限(更問・聞き返しへの返答とも各ルームこの回数まで)
    private var devFollowupCounts: [String: Int] = [:] // roomId → 更問の回数(ループ防止)
    private var devClarifyCounts: [String: Int] = [:]  // roomId → 聞き返しへの返答回数
    private var devRepliedMsgIds: Set<String> = []     // 返信済みメッセージID(二重返信防止)

    private let db = Firestore.firestore()
    private let wid: String
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listeners: [ListenerRegistration] = []
    private var roomMsgListener: ListenerRegistration?

    var isExpert: Bool { role == .expert }

    /// 表示名: ニックネーム優先、なければメールアドレス(Web版 myName)
    func myName() -> String {
        let n = nickname.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (user?.email ?? "") : n
    }

    // MARK: - 完了ステータス・案件の可視判定(Web版と同一)

    func isDoneRoom(_ roomId: String) -> Bool {
        rooms.contains { $0.id == roomId && $0.isDone }
    }

    /// 完了にした相談の案件はBAタブに出さない
    var visibleCases: [CaseItem] {
        cases.filter { !isDoneRoom($0.roomId) }
    }

    var pendingCaseCount: Int {
        visibleCases.filter { $0.status != .answered }.count
    }

    /// 未回答かつ対応者が決まっていない案件の数(相談一覧タブのバッジ用)
    var unassignedCaseCount: Int {
        visibleCases.filter { $0.status != .answered && $0.handledBy.isEmpty }.count
    }

    init() {
        // 合言葉の SHA-256 がワークスペースID(Web版と同じ)
        let digest = SHA256.hash(data: Data(FirebaseSetup.workspaceCode.utf8))
        wid = digest.map { String(format: "%02x", $0) }.joined()

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                await self?.authChanged(user)
            }
        }
    }

    private func wsRef() -> DocumentReference { db.collection("workspaces").document(wid) }

    private func authChanged(_ user: User?) async {
        self.user = user
        if let user {
            subscribeAll()
            // 役割・ニックネーム・回答の癖(アカウントごと)を取得(未登録なら選択値・入力値で作成)
            let mref = wsRef().collection("members").document(user.uid)
            do {
                let snap = try await mref.getDocument()
                if let r = snap.data()?["role"] as? String, let mr = MemberRole(rawValue: r) {
                    role = mr
                    nickname = snap.data()?["nickname"] as? String ?? ""
                    answerStyle = snap.data()?["answerStyle"] as? String ?? ""
                } else {
                    role = pendingRole
                    nickname = pendingNickname
                    answerStyle = ""
                    try await mref.setData([
                        "email": user.email ?? "",
                        "role": pendingRole.rawValue,
                        "nickname": pendingNickname,
                        "createdAt": nowIso(),
                    ])
                }
            } catch {
                role = pendingRole
                nickname = pendingNickname
            }
            pendingNickname = ""
            // メンバー情報(役割・ニックネーム・回答の癖)を常時同期する。
            // Web版で「回答の癖」を編集した場合も、アプリを再起動せずに反映される。
            listeners.append(mref.addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, let d = snap?.data() else { return }
                    if let r = d["role"] as? String, let mr = MemberRole(rawValue: r) { self.role = mr }
                    self.nickname = d["nickname"] as? String ?? ""
                    self.answerStyle = d["answerStyle"] as? String ?? ""
                }
            })
        } else {
            role = nil
            nickname = ""
            answerStyle = ""
            unsubscribeAll()
            closeRoomView()
            rooms = []; cases = []; qaLog = []; manuals = []
            naiki = Prompts.defaultNaiki
            activeTab = .chat
        }
        authReady = true
    }

    // MARK: - 認証

    func login(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signup(email: String, password: String, role: MemberRole, nickname: String) async throws {
        pendingRole = role
        pendingNickname = nickname
        try await Auth.auth().createUser(withEmail: email, password: password)
    }

    func logout() {
        try? Auth.auth().signOut()
    }

    static func authErrorMessage(_ error: Error) -> String {
        guard let code = AuthErrorCode(rawValue: (error as NSError).code) else {
            return "認証に失敗しました: \(error.localizedDescription)"
        }
        switch code {
        case .invalidCredential, .wrongPassword, .userNotFound:
            return "メールアドレスまたはパスワードが違います。"
        case .invalidEmail:
            return "メールアドレスの形式が正しくありません。"
        case .emailAlreadyInUse:
            return "このメールアドレスは既に登録されています。ログインしてください。"
        case .weakPassword:
            return "パスワードは6文字以上にしてください。"
        case .tooManyRequests:
            return "試行回数が多すぎます。しばらく待ってから再度お試しください。"
        case .operationNotAllowed:
            return "メール/パスワード認証が有効になっていません(Firebaseコンソールで有効化してください)。"
        default:
            return "認証に失敗しました: \(error.localizedDescription)"
        }
    }

    /// 回答の癖(アカウントごと)を保存
    func saveAnswerStyle(_ style: String) {
        answerStyle = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid = user?.uid else { return }
        wsRef().collection("members").document(uid).setData(["answerStyle": answerStyle], merge: true)
    }

    // MARK: - 購読

    private func subscribeAll() {
        unsubscribeAll()

        // 社内ルール(ワークスペース直下の naiki フィールド)
        listeners.append(wsRef().addSnapshotListener { [weak self] snap, _ in
            guard let self else { return }
            Task { @MainActor in
                if let naiki = snap?.data()?["naiki"] as? String {
                    self.naiki = naiki
                } else if snap != nil {
                    // ワークスペース未作成 → 既定の社内ルールで初期化(既存は上書きしない)
                    try? await self.wsRef().setData(["naiki": self.naiki], merge: true)
                }
            }
        })

        // 社内マニュアル
        listeners.append(wsRef().collection("manuals").order(by: "updatedAt").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.manuals = snap?.documents.compactMap { Manual(dict: $0.data()) } ?? []
            }
        })

        // 相談ルーム一覧
        // orderByは付けない: lastTsが無い/型が違うドキュメントが黙って除外されるため。
        // 並び替えはクライアント側で行う(Web版と同じ)。
        listeners.append(wsRef().collection("rooms").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.rooms = snap?.documents.compactMap { Room(dict: $0.data()) } ?? []
            }
        })

        // エスカレーション案件
        listeners.append(wsRef().collection("cases").order(by: "askedAt").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.cases = snap?.documents.compactMap { CaseItem(dict: $0.data()) } ?? []
                self?.devMaybeReply() // 案件が回答済みになったタイミングでも担当者役の返信を判定
            }
        })

        // Q&Aログ(ダウンロード用)
        listeners.append(wsRef().collection("qa").order(by: "answered_at").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.qaLog = snap?.documents.map { QaEntry(dict: $0.data()) } ?? []
            }
        })
    }

    private func unsubscribeAll() {
        listeners.forEach { $0.remove() }
        listeners = []
    }

    // MARK: - ルーム操作

    func myUid() -> String { user?.uid ?? "local" }
    func isMyRoom(_ r: Room) -> Bool { r.ownerUid.isEmpty || r.ownerUid == myUid() }
    /// 財務(BA)は相談を削除できない。担当者は自分の相談のみ削除可
    func canDeleteRoom(_ r: Room) -> Bool { !isExpert && isMyRoom(r) }

    func currentRoom() -> Room? {
        rooms.first { $0.id == currentRoomId }
            ?? (pendingRoom?.id == currentRoomId ? pendingRoom : nil)
    }

    /// 新規相談: この時点では保存せず、最初のメッセージ送信時に保存する(空の相談を残さない)
    func createRoom() {
        guard !isExpert else { return }
        stopRoomMessages()
        let room = Room(ownerUid: myUid(), ownerEmail: user?.email ?? "", ownerName: myName())
        pendingRoom = room
        currentRoomId = room.id
        roomMessages = []
        chatPath = [room.id]
    }

    func openRoom(_ id: String) {
        pendingRoom = nil // 別ルームを開いたら未送信の下書きは破棄
        currentRoomId = id
        subscribeRoomMessages(id)
        if chatPath != [id] { chatPath = [id] }
    }

    func backToRooms() { closeRoomView() }

    /// ナビゲーションの「戻る」やスワイプで相談が閉じられたときの後始末
    func handleChatPathChange() {
        if chatPath.isEmpty, currentRoomId != nil { closeRoomView() }
    }

    private func closeRoomView() {
        pendingRoom = nil
        currentRoomId = nil
        stopRoomMessages()
        roomMessages = []
        if !chatPath.isEmpty { chatPath = [] }
    }

    private func subscribeRoomMessages(_ id: String) {
        stopRoomMessages()
        roomMessages = []
        roomMsgListener = wsRef().collection("rooms").document(id).collection("messages")
            .order(by: "ts").addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    self?.roomMessages = snap?.documents.compactMap { Message(dict: $0.data()) } ?? []
                    self?.markRoomRead() // 表示中のメッセージを既読にする
                    self?.devMaybeReply() // 開発モード: 担当者役の返信が必要か判定(既存の相談を開いたときも動く)
                }
            }
    }

    private func stopRoomMessages() {
        roomMsgListener?.remove()
        roomMsgListener = nil
    }

    /// 開いている相談のメッセージを既読にする(rooms/{id}.reads.{uid} に最後に読んだ ts を記録)
    private func markRoomRead() {
        guard let uid = user?.uid, let roomId = currentRoomId,
              let room = rooms.first(where: { $0.id == roomId }),
              let lastTs = roomMessages.last?.ts, !lastTs.isEmpty else { return }
        let current = room.reads[uid] ?? ""
        guard lastTs > current else { return }
        wsRef().collection("rooms").document(roomId).updateData(["reads.\(uid)": lastTs])
    }

    /// メッセージ追加。未送信の新規相談(pendingRoom)は最初のメッセージで保存する(Web版 addMessage と同じ)
    func addMessage(_ msg: Message, roomId: String? = nil) {
        guard let roomId = roomId ?? currentRoomId else { return }
        let lastText = msg.role == .expert ? "【BA】" + msg.text : msg.text
        let roomRef = wsRef().collection("rooms").document(roomId)

        if var room = pendingRoom, room.id == roomId {
            pendingRoom = nil
            room.lastText = lastText
            room.lastTs = msg.ts
            if msg.role == .user { room.title = snippet(msg.text, 30) }
            roomRef.setData(room.dict)
            subscribeRoomMessages(room.id)
        } else {
            var patch: [String: Any] = ["lastText": lastText, "lastTs": msg.ts]
            let r = rooms.first { $0.id == roomId }
            if msg.role == .user, r == nil || r!.title.isEmpty || r!.title == "新しい相談" {
                patch["title"] = snippet(msg.text, 30)
            }
            roomRef.updateData(patch)
        }
        roomRef.collection("messages").document(msg.id).setData(msg.dict)
    }

    /// メッセージ本文を編集する(最後のメッセージなら一覧のプレビューも更新)
    func updateMessageText(_ msg: Message, newText: String) {
        guard let roomId = currentRoomId else { return }
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != msg.text else { return }
        let roomRef = wsRef().collection("rooms").document(roomId)
        roomRef.collection("messages").document(msg.id).updateData(["text": text])
        if roomMessages.last?.id == msg.id {
            let lastText = msg.role == .expert ? "【BA】" + text : text
            roomRef.updateData(["lastText": lastText])
        }
    }

    /// メッセージを削除する(最後のメッセージなら一覧のプレビューも更新)
    func deleteMessage(_ msg: Message) {
        guard let roomId = currentRoomId else { return }
        let roomRef = wsRef().collection("rooms").document(roomId)
        roomRef.collection("messages").document(msg.id).delete()
        if roomMessages.last?.id == msg.id {
            let remaining = roomMessages.filter { $0.id != msg.id }
            if let last = remaining.last {
                let lastText = last.role == .expert ? "【BA】" + last.text : last.text
                roomRef.updateData(["lastText": lastText, "lastTs": last.ts])
            } else {
                // メッセージが無くなった相談は一覧に表示されなくなる(空の下書きと同じ扱い)
                roomRef.updateData(["lastText": ""])
            }
        }
    }

    func deleteRoom(_ id: String) async {
        guard let r = rooms.first(where: { $0.id == id }), canDeleteRoom(r) else { return }
        do {
            let roomRef = wsRef().collection("rooms").document(id)
            let msgs = try await roomRef.collection("messages").getDocuments()
            for d in msgs.documents { try await d.reference.delete() }
            for c in cases where c.roomId == id {
                try await wsRef().collection("cases").document(c.id).delete()
            }
            try await roomRef.delete()
        } catch {
            print("deleteRoom error: \(error)")
        }
        if currentRoomId == id { closeRoomView() }
    }

    /// 相談の完了ステータスを切り替え(財務と相談の本人のみ)
    func toggleRoomDone(_ roomId: String) {
        guard let r = rooms.first(where: { $0.id == roomId }),
              isExpert || isMyRoom(r) else { return }
        let status = r.isDone ? "" : "done"
        if let i = rooms.firstIndex(where: { $0.id == roomId }) {
            rooms[i].status = status // 先に画面へ反映(Firestoreの反映を待たない)
        }
        wsRef().collection("rooms").document(roomId).updateData(["status": status])
    }

    /// 相談をすべて削除(財務のみ。ルーム・メッセージ・BA案件・回答履歴を全消去)
    func deleteAllRooms() async throws {
        guard isExpert else { return }
        let rsnap = try await wsRef().collection("rooms").getDocuments()
        for rd in rsnap.documents {
            let msnap = try await rd.reference.collection("messages").getDocuments()
            for md in msnap.documents { try await md.reference.delete() }
            try await rd.reference.delete()
        }
        let csnap = try await wsRef().collection("cases").getDocuments()
        for cd in csnap.documents { try await cd.reference.delete() }
        let qsnap = try await wsRef().collection("qa").getDocuments()
        for qd in qsnap.documents { try await qd.reference.delete() }
        closeRoomView()
    }

    /// チャットからBAタブの該当案件へジャンプ(未回答の案件を優先)
    func jumpToCase(roomId: String) {
        let c = cases.first { $0.roomId == roomId && $0.status != .answered }
            ?? cases.first { $0.roomId == roomId }
        guard let c else { return }
        activeTab = .expert
        highlightCaseId = c.id
    }

    /// BAタブから元の相談(トークルーム)を開く
    func openRoomFromCase(_ c: CaseItem) {
        guard !c.roomId.isEmpty else { return }
        activeTab = .chat
        openRoom(c.roomId)
    }

    // MARK: - 案件・Q&A

    func addCase(_ c: CaseItem) {
        wsRef().collection("cases").document(c.id).setData(c.dict)
    }

    func updateCase(_ id: String, _ patch: [String: Any]) {
        wsRef().collection("cases").document(id).updateData(patch)
    }

    /// 対応者のトグル(自分が対応者なら外す、そうでなければ自分を設定)
    func toggleHandler(_ c: CaseItem) {
        let me = myName()
        guard !me.isEmpty else { return }
        updateCase(c.id, ["handledBy": c.handledBy == me ? "" : me])
    }

    func addQa(_ entry: QaEntry) {
        wsRef().collection("qa").addDocument(data: entry.dict)
    }

    // MARK: - マニュアル

    func addManual(title: String, content: String, pdfData: String? = nil, id: String? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        let m = Manual(id: id ?? newUid(), title: t.isEmpty ? "無題のマニュアル" : t, content: c, pdfData: pdfData)
        wsRef().collection("manuals").document(m.id).setData(m.dict)
    }

    func deleteManual(_ id: String) {
        wsRef().collection("manuals").document(id).delete()
    }

    // MARK: - 社内ルール

    /// 社内ルールをクラウドに保存(全員に反映)
    func saveNaiki(_ text: String) {
        naiki = text
        wsRef().setData(["naiki": text], merge: true)
    }

    /// 社内ルールの末尾に追記
    func appendToNaiki(_ add: String, separator: String = "\n") {
        var cur = naiki
        while let last = cur.last, last.isWhitespace || last.isNewline { cur.removeLast() }
        saveNaiki(cur + (cur.isEmpty ? "" : separator) + add)
    }

    /// 社内ルールをAIで整理してコンパクトにした案を返す(置き換えは呼び出し側で確認後に saveNaiki)
    func compactNaiki() async throws -> String {
        let cur = naiki.trimmingCharacters(in: .whitespacesAndNewlines)
        let compacted = try await ClaudeService.call(
            system: Prompts.naikiCompactSystem,
            messages: [.init(role: "user", content: "以下の社内ルールを、内容を変えずに整理してコンパクトにしてください。\n\n\(cur)")]
        )
        return compacted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 相談(複数可)のやり取りから、既存の社内ルールにない項目(差分)を抽出する
    func suggestNaikiFromRooms(_ roomIds: [String]) async throws -> String {
        var parts: [String] = []
        let multi = roomIds.count > 1
        for roomId in roomIds {
            let snap = try await wsRef().collection("rooms").document(roomId)
                .collection("messages").order(by: "ts").getDocuments()
            let msgs = snap.documents.compactMap { Message(dict: $0.data()) }
            if msgs.isEmpty { continue }
            let conv = msgs.map { m -> String in
                let who: String
                switch m.role {
                case .user: who = "質問者"
                case .expert: who = "専門家"
                case .ai: who = "AI"
                case .system: who = "システム"
                }
                return "\(who): \(m.text)"
            }.joined(separator: "\n")
            if multi {
                let title = rooms.first { $0.id == roomId }?.title ?? "相談"
                parts.append("◆ 相談「\(title)」\n\(conv)")
            } else {
                parts.append(conv)
            }
        }
        let convAll = parts.joined(separator: "\n\n")
        guard !convAll.isEmpty else {
            throw ClaudeService.ClaudeError.server("選択した相談にはまだやり取りがありません。")
        }
        let subject = multi ? "以下は複数の相談のやり取りです。" : "以下はこの相談のやり取りです。"
        let existing = naiki.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMsg = existing.isEmpty
            ? "\(subject)この対応をふまえ、社内ルールに追記すべきルールを箇条書きで提案してください。\n\n\(convAll)"
            : "以下は現在の社内ルールです。\n----- 現在の社内ルールここから -----\n\(existing)\n----- 現在の社内ルールここまで -----\n\n\(subject)この対応から社内ルールとして明文化できる項目のうち、現在の社内ルールで既にカバーされている項目は除外し、不足している項目のみを箇条書きで抽出してください。不足がなければ「\(Prompts.noDiffText)」とだけ返してください。\n\n\(convAll)"
        let suggestion = try await ClaudeService.call(
            system: Prompts.naikiSuggestSystem,
            messages: [.init(role: "user", content: userMsg)]
        )
        return suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// マニュアル本文から、既存の社内ルールにない項目(差分)を抽出する
    func extractNaikiFromManuals(_ src: String) async throws -> String {
        var src = src
        if src.count > 12000 { src = String(src.prefix(12000)) + "\n…(以下省略)" }
        let existing = naiki.trimmingCharacters(in: .whitespacesAndNewlines)
        var userMsg = ""
        if !existing.isEmpty {
            userMsg += "以下は現在の社内ルールです。\n----- 現在の社内ルールここから -----\n\(existing)\n----- 現在の社内ルールここまで -----\n\n"
        }
        userMsg += "以下は社内マニュアルです。マニュアルから社内ルール(会計処理のルール)として明文化できる項目を抽出してください。\n"
        userMsg += "抽出の条件:\n"
        userMsg += "- 法令の一般的なルールなど、一般的な会計・税務の知識として生成AIが自力で答えられる内容は除外し、この会社・事務所に固有のルール(社内の金額基準・承認手続き・独自の方針など)だけを対象にする\n"
        if !existing.isEmpty {
            userMsg += "- 現在の社内ルールで既にカバーされている項目は除外し、不足している項目のみを抽出する\n"
        }
        userMsg += "該当する項目がなければ「\(Prompts.noDiffText)」とだけ返してください。\n\n\(src)"
        let extracted = try await ClaudeService.call(
            system: Prompts.naikiExtractSystem,
            messages: [.init(role: "user", content: userMsg)]
        )
        return extracted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 質問送信(トリアージ)

    /// 財務、および他人の相談を開いた担当者は送信不可(閲覧のみ)
    var canSendInCurrentRoom: Bool {
        if isExpert { return false }
        guard let r = currentRoom() else { return true }
        return isMyRoom(r)
    }

    /// `simulated` = 開発モードの担当者役(API)による送信(財務の端末からでも送れる)
    func submitQuestion(_ text: String, simulated: Bool = false) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, currentRoomId != nil,
              simulated || canSendInCurrentRoom else { return }

        sending = true
        pendingTyping = true
        let roomId = currentRoomId!
        addMessage(Message(role: .user, text: text))

        defer {
            pendingTyping = false
            sending = false
        }

        do {
            // このルーム内の直近の会話履歴をコンテキストとして渡す
            var history = roomMessages
                .filter { $0.role == .user || $0.role == .ai || $0.role == .expert }
                .suffix(20)
                .map { ClaudeService.ChatMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
            if history.last?.role != "user" {
                history.append(.init(role: "user", content: text))
            }

            let raw = try await ClaudeService.call(
                system: Prompts.withNaiki(Prompts.triageSystem, naiki: naiki, manuals: manuals),
                messages: history,
                schema: Prompts.triageSchema
            )
            let result = try JSONDecoder().decode(TriageResult.self, from: Data(raw.utf8))

            if result.decision == "answer", !result.answer.isEmpty {
                addMessage(Message(role: .ai, text: result.answer), roomId: roomId)
                addQa(QaEntry(question: text, answeredBy: "AI", answer: result.answer,
                              askedAt: nowIso(), answeredAt: nowIso()))
            } else if result.decision == "clarify", !result.clarify_question.isEmpty {
                // 情報不足 → 短い質問+選択肢ボタンで聞き返す
                addMessage(Message(role: .ai, text: result.clarify_question,
                                   clarifyOptions: result.clarify_options), roomId: roomId)
            } else {
                // エスカレーション
                let caseObj = CaseItem(
                    roomId: roomId,
                    question: text,
                    reason: result.escalation_reason.isEmpty ? "専門家の確認が必要な質問です。" : result.escalation_reason,
                    options: result.options.isEmpty ? ["質問内容を確認のうえ個別に回答する"] : result.options
                )
                addCase(caseObj)
                addMessage(Message(role: .ai, text: "ご質問ありがとうございます。この内容はBAによる確認が必要なため、BAにおつなぎしました。回答までしばらくお待ちください。"), roomId: roomId)
            }
        } catch {
            addMessage(Message(role: .system, text: "⚠ " + error.localizedDescription), roomId: roomId)
        }
    }

    // MARK: - BA(専門家)アクション

    /// 選択肢ごとにマニュアルの該当箇所をAIで探し、案件に保存する(全員に共有)
    func fetchManualRefs(for c: CaseItem) async throws {
        guard !manuals.isEmpty else { return }
        var mtxt = manuals.map { "# \($0.title.isEmpty ? "無題" : $0.title)\n\($0.content)" }.joined(separator: "\n\n")
        if mtxt.count > 10000 { mtxt = String(mtxt.prefix(10000)) + "\n…(以下省略)" }
        let optList = c.options.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let raw = try await ClaudeService.call(
            system: Prompts.manualRefSystem,
            messages: [.init(role: "user", content: "質問:\n\(c.question)\n\n回答方針の選択肢:\n\(optList)\n\n----- 社内マニュアルここから -----\n\(mtxt)\n----- 社内マニュアルここまで -----")],
            schema: Prompts.manualRefSchema
        )
        let result = try JSONDecoder().decode(ManualRefsResult.self, from: Data(raw.utf8))
        let refs = result.refs
            .filter { $0.option >= 0 && $0.option < c.options.count }
            .map { ManualRef(option: $0.option, manual: $0.manual, excerpt: $0.excerpt) }
        updateCase(c.id, ["manualRefs": refs.map { $0.dict }])
    }

    /// 回答文(案)を生成
    func generateDraft(for c: CaseItem, direction: String) async throws {
        let draft = try await ClaudeService.call(
            system: Prompts.withNaiki(Prompts.draftSystem, naiki: naiki, manuals: manuals, answerStyle: answerStyle),
            messages: [.init(role: "user", content: """
            質問者からの質問:
            \(c.question)

            AIがエスカレーションした理由:
            \(c.reason)

            専門家が指定した回答方針:
            \(direction)

            この方針に沿った回答文(案)を作成してください。
            """)]
        )
        updateCase(c.id, ["draft": draft.trimmingCharacters(in: .whitespacesAndNewlines),
                          "status": CaseStatus.drafted.rawValue])
    }

    /// 回答を承認して質問者に送信
    func approveCase(_ c: CaseItem, finalText: String) {
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let handler = c.handledBy.isEmpty ? myName() : c.handledBy
        addMessage(Message(role: .expert, text: text), roomId: c.roomId)
        addQa(QaEntry(
            question: c.question,
            answeredBy: "BA",
            handler: handler,
            selectedOption: c.selectedOption.flatMap { c.options.indices.contains($0) ? c.options[$0] : nil } ?? "(自由/音声入力)",
            answer: text,
            askedAt: c.askedAt,
            answeredAt: nowIso()
        ))
        updateCase(c.id, ["answer": text, "status": CaseStatus.answered.rawValue,
                          "answeredAt": nowIso(), "handledBy": handler])
    }

    // MARK: - 開発モード(APIによる担当者役)

    /// 開いている相談が「担当者の返答待ち」の状態なら、担当者役の返信をスケジュールする。
    /// メッセージ・案件の更新のたびに呼ばれるため、既存の「担当者回答待ち」の相談を開いたときも動く。
    private func devMaybeReply() {
        guard devMode, let roomId = currentRoomId, let last = roomMessages.last else { return }
        guard last.role == .ai || last.role == .expert else { return }
        guard !devRepliedMsgIds.contains(last.id), !isDoneRoom(roomId) else { return }
        // 未回答の案件がある(=BA回答待ち)ときはBAの回答を待つ
        guard !cases.contains(where: { $0.roomId == roomId && $0.status != .answered }) else { return }
        devRepliedMsgIds.insert(last.id)
        let isClarify = last.role == .ai && !last.clarifyOptions.isEmpty
        scheduleDevQuestionerReply(roomId: roomId, isFollowup: !isClarify)
    }

    /// APIが担当者役(会計の素人)として返信する。
    /// 聞き返しには返答し、AI/BAの回答には納得するまで更問をする。
    /// 納得した場合(または更問の上限に達した場合)はお礼を送って相談を完了にする。
    private func scheduleDevQuestionerReply(roomId: String, isFollowup: Bool) {
        guard devMode else { return }
        // 更問の上限に達したら、納得したことにしてお礼+完了
        let followupLimitReached = isFollowup && devFollowupCounts[roomId, default: 0] >= devReplyLimit
        if isFollowup && !followupLimitReached {
            devFollowupCounts[roomId, default: 0] += 1
        } else if !isFollowup {
            guard devClarifyCounts[roomId, default: 0] < devReplyLimit else { return }
            devClarifyCounts[roomId, default: 0] += 1
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // 待機中にオフにされたら送らない
            guard let self, self.devMode, self.currentRoomId == roomId, !self.sending else { return }

            if followupLimitReached {
                self.devFinishRoom(roomId, thanks: "ありがとうございます、よく分かりました!")
                return
            }

            // 会話履歴を台本テキストとして1つのメッセージにまとめて渡す
            // (roleを反転して渡すと構造が不正になり、モデルがアーティファクトを出すため)
            let transcript = self.roomMessages
                .filter { $0.role != .system }
                .suffix(20)
                .map { m -> String in
                    switch m.role {
                    case .user: return "質問者: \(m.text)"
                    case .ai: return "AIアシスタント: \(m.text)"
                    case .expert: return "会計専門家(BA): \(m.text)"
                    case .system: return ""
                    }
                }
                .joined(separator: "\n\n")
            guard !transcript.isEmpty else { return }
            do {
                let raw = try await ClaudeService.call(
                    system: Prompts.devQuestionerSystem,
                    messages: [.init(role: "user", content: """
                    以下は会計相談チャットのこれまでのやり取りです。あなたは「質問者」です。
                    このやり取りの続きとして、質問者が次に送るメッセージを決めてください。

                    \(transcript)
                    """)],
                    schema: Prompts.devQuestionerSchema
                )
                let result = try JSONDecoder().decode(DevQuestionerResult.self, from: Data(raw.utf8))
                let text = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, self.currentRoomId == roomId else { return }
                if result.satisfied && isFollowup {
                    // 納得した → お礼を送って完了にする
                    self.devFinishRoom(roomId, thanks: text)
                } else {
                    await self.submitQuestion(text, simulated: true)
                }
            } catch {
                // 開発モードの自動返信は失敗しても通常フローに影響させない
            }
        }
    }

    /// 担当者役がお礼を送って相談を完了にする
    private func devFinishRoom(_ roomId: String, thanks: String) {
        addMessage(Message(role: .user, text: thanks), roomId: roomId)
        if let r = rooms.first(where: { $0.id == roomId }), !r.isDone {
            toggleRoomDone(roomId)
        }
    }
}
