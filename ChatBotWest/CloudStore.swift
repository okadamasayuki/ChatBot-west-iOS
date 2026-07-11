import Foundation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore

enum AppTab: Hashable {
    case chat, baChat, notifications, expert, naiki, manual, membersList, settings
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
    @Published var myIcon: String = ""     // 自分のアイコン(絵文字)
    @Published var myIconData: String = "" // 自分のアイコン画像(base64 JPEG。こちらを優先)
    @Published var authReady = false
    var pendingRole: MemberRole = .questioner   // 新規登録時に使う
    var pendingNickname: String = ""
    var pendingCompanies: [String] = []
    var pendingDepartment: String = ""
    var pendingSection: String = ""
    var pendingPosition: String = ""

    // MARK: - 共有データ
    @Published var naiki: String = Prompts.defaultNaiki
    @Published var rooms: [Room] = []
    @Published var cases: [CaseItem] = []
    @Published var qaLog: [QaEntry] = []
    @Published var manuals: [Manual] = []

    // 組織の選択肢(会社・部署・担当)。ワークスペース設定で編集でき、全員に同期される
    @Published var orgCompanies: [String] = CloudStore.cachedList("orgCompanies") ?? Companies.all
    @Published var orgDepartments: [String: [String]] = CloudStore.cachedMap("orgDepartmentsMap") ?? Departments.byCompany
    @Published var orgSections: [String: [String]] = CloudStore.cachedMap("orgSections2") ?? Departments.defaultOrgSections()

    /// 会社に紐づく部署の選択肢
    func departments(for company: String) -> [String] {
        orgDepartments[company] ?? []
    }

    /// 会社+部署に紐づく担当の選択肢
    func sections(company: String, department: String) -> [String] {
        orgSections[CloudStore.sectionKey(company, department)] ?? []
    }

    static func sectionKey(_ company: String, _ department: String) -> String {
        "\(company)|\(department)"
    }

    /// 全社の部署の選択肢(重複なし・会社順)
    var allDepartments: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in orgCompanies {
            for d in orgDepartments[c] ?? [] where !seen.contains(d) {
                seen.insert(d); out.append(d)
            }
        }
        return out
    }

    struct MemberInfo: Identifiable, Equatable {
        let id: String   // uid
        let name: String // ニックネーム(なければメール)
        let role: String
        var icon: String = ""      // アイコン(絵文字)
        var iconData: String = ""  // アイコン画像(base64 JPEG。こちらを優先表示)
        var email: String = ""
        var companies: [String] = [] // 所属会社(複数所属あり)
        var department: String = ""  // 所属部署
        var section: String = ""     // 所属担当
        var position: String = ""    // 役職

        init(id: String, name: String, role: String, icon: String = "", iconData: String = "", email: String = "",
             companies: [String] = [], department: String = "", section: String = "", position: String = "") {
            self.id = id; self.name = name; self.role = role; self.icon = icon; self.iconData = iconData
            self.email = email
            self.companies = companies
            self.department = department
            self.section = section
            self.position = position
        }

        /// 「ウエスト株式会社・経理部・財務担当・課長」のような所属表示
        var affiliation: String {
            ([companies.joined(separator: "/")] + [department, section, position])
                .filter { !$0.isEmpty }.joined(separator: "・")
        }
    }

    /// uid からメンバー情報を引く
    func member(_ uid: String) -> MemberInfo? {
        members.first { $0.id == uid }
    }
    @Published var members: [MemberInfo] = []

    // BAトーク(財務同士のトークルーム)
    @Published var baTalks: [BaTalk] = []
    @Published var pinnedTalkOrder: [String] = []  // ピン留めトークの並び順(アカウントごとにmembersへ保存)
    @Published var baTalkPath: [String] = []       // NavigationStack のパス
    @Published var currentBaTalkId: String?
    @Published var baTalkMessages: [BaMessage] = []
    private var baTalkMsgListener: ListenerRegistration?

    /// BA(財務)メンバーの表示名一覧(対応依頼の宛先に使う)
    var expertNames: [String] {
        members.filter { $0.role == MemberRole.expert.rawValue && !$0.name.isEmpty }.map { $0.name }
    }

    // MARK: - 画面状態
    @Published var activeTab: AppTab = .chat
    @Published var highlightCaseId: String?   // BAタブでハイライトする案件(チャットからのジャンプ)
    @Published var chatPath: [String] = []    // NavigationStack のパス(相談を開くとプッシュ遷移)
    /// 送信せずに画面を離れたときの下書き(ルーム/トークごと。端末内のみ)
    var roomDrafts: [String: String] = [:]
    var baDrafts: [String: String] = [:]

    /// 通知タブに貯めるアプリ内通知(端末内に保存)
    struct AppNotification: Identifiable, Codable, Equatable {
        var id: String
        var ts: String
        var kind: String        // "room" | "baTalk"
        var targetId: String
        var title: String
        var body: String
        var read: Bool
    }
    @Published var notifications: [AppNotification] = []
    /// トークごとの未読メッセージ数(LINE式のバッジ表示用)
    @Published var talkUnread: [String: Int] = [:]
    /// 未読数の集計世代。古い getDocuments の結果が新しい集計を上書きしないようにする
    private var talkUnreadGeneration = 0
    /// 新着検知用: 前回見た lastTs(端末に保存し、アプリを閉じている間の新着も次回起動時に通知する)
    private var roomNotifyTs: [String: String] = [:]
    private var talkNotifyTs: [String: String] = [:]
    private var roomNotifyPrimed = false
    private var talkNotifyPrimed = false

    var unreadNotificationCount: Int {
        notifications.filter { !$0.read }.count
    }

    /// BAチャット全トークの未読合計(タブバッジ用)
    var totalTalkUnread: Int {
        let uid = myUid()
        return baTalks.filter { $0.memberUids.contains(uid) }
            .reduce(0) { $0 + (talkUnread[$1.id] ?? 0) }
    }
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
    @Published var devTypingRoomId: String?            // 担当者役が返信を生成中の相談(「入力中…」表示用)

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
                        "companies": pendingCompanies,
                        "department": pendingDepartment,
                        "section": pendingSection,
                        "position": pendingPosition,
                        "createdAt": nowIso(),
                    ])
                }
            } catch {
                role = pendingRole
                nickname = pendingNickname
            }
            pendingNickname = ""
            // 通知(端末内)を読み込み、検知の基準をリセット
            loadNotifications()
            roomNotifyPrimed = false
            talkNotifyPrimed = false
            roomNotifyTs = [:]
            talkNotifyTs = [:]
            // 役割の取得を待つ間にスナップショットが先に届いていると、
            // isExpert 未確定のまま未読・通知の計算を素通りしているのでここでやり直す
            detectRoomNotifications()
            detectTalkNotifications()
            refreshTalkUnreadCounts()
            // メンバー情報(役割・ニックネーム・回答の癖)を常時同期する。
            // Web版で「回答の癖」を編集した場合も、アプリを再起動せずに反映される。
            listeners.append(mref.addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, let d = snap?.data() else { return }
                    if let r = d["role"] as? String, let mr = MemberRole(rawValue: r) { self.role = mr }
                    self.nickname = d["nickname"] as? String ?? ""
                    self.answerStyle = d["answerStyle"] as? String ?? ""
                    self.pinnedTalkOrder = d["pinnedTalkOrder"] as? [String] ?? []
                    self.myIcon = d["icon"] as? String ?? ""
                    self.myIconData = d["iconData"] as? String ?? ""
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

    func signup(email: String, password: String, role: MemberRole, nickname: String,
                companies: [String], department: String, section: String, position: String) async throws {
        pendingRole = role
        pendingNickname = nickname
        pendingCompanies = companies
        pendingDepartment = department
        pendingSection = section
        pendingPosition = position
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

    /// 組織の選択肢を保存(ログイン画面用に端末にもキャッシュする)
    func saveOrgConfig() {
        wsRef().collection("config").document("org").setData([
            "companies": orgCompanies,
            "departments": orgDepartments,
            "sections": orgSections,
        ], merge: true)
        cacheOrgConfig()
    }

    private func cacheOrgConfig() {
        let ud = UserDefaults.standard
        ud.set(orgCompanies, forKey: "orgCompanies")
        ud.set(orgDepartments, forKey: "orgDepartmentsMap")
        ud.set(orgSections, forKey: "orgSections2")
    }

    static func cachedList(_ key: String) -> [String]? {
        let v = UserDefaults.standard.stringArray(forKey: key)
        return (v?.isEmpty ?? true) ? nil : v
    }

    static func cachedMap(_ key: String) -> [String: [String]]? {
        let v = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]
        return (v?.isEmpty ?? true) ? nil : v
    }

    // MARK: - 通知タブ(アプリ内通知)

    /// 新着検知の基準(前回見た lastTs)は端末に保存し、アプリを閉じている間の新着も次回起動時に通知する
    private func notifyTsKey(_ kind: String) -> String { "notifyTs-\(kind)-\(myUid())" }

    /// 保存済みの基準を読み込んで検知を始める。基準が無い初回だけ、いま見えているものを基準にする(過去分は通知しない)
    /// - Returns: false = まだデータが無く準備できていない
    private func primeNotifyTs(_ dict: inout [String: String], kind: String, currentTs: [String: String]) -> Bool {
        guard !currentTs.isEmpty else { return false }
        dict = UserDefaults.standard.dictionary(forKey: notifyTsKey(kind)) as? [String: String] ?? [:]
        if dict.isEmpty {
            dict = currentTs
            UserDefaults.standard.set(dict, forKey: notifyTsKey(kind))
        }
        return true
    }

    /// 自分が担当中の相談に新しいメッセージ(質問者の返答など)が来たら通知に積む
    private func detectRoomNotifications() {
        guard isExpert else { return }
        if !roomNotifyPrimed {
            let current = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0.lastTs) })
            roomNotifyPrimed = primeNotifyTs(&roomNotifyTs, kind: "room", currentTs: current)
            guard roomNotifyPrimed else { return }
        }
        for r in rooms {
            let prev = roomNotifyTs[r.id] ?? "" // 基準が無い相談(前回起動後に作られた)は新着扱い
            roomNotifyTs[r.id] = r.lastTs
            guard r.lastTs > prev else { continue }
            guard r.lastTs > (r.reads[myUid()] ?? "") else { continue } // 既読済み(Web版で読んだ等)は通知不要
            guard !r.handler.isEmpty, r.handler == myName() else { continue }
            guard currentRoomId != r.id else { continue }          // 開いている相談は通知不要
            guard !r.lastText.hasPrefix("【BA】") else { continue } // 自分(BA)の回答は通知不要
            addNotification(kind: "room", targetId: r.id,
                            title: "相談: \(r.title.isEmpty ? "相談" : r.title)",
                            body: snippet(r.lastText, 60))
        }
        UserDefaults.standard.set(roomNotifyTs, forKey: notifyTsKey("room"))
    }

    /// BAトークに新着メッセージが来たら通知に積む
    private func detectTalkNotifications() {
        guard isExpert else { return }
        if !talkNotifyPrimed {
            let current = Dictionary(uniqueKeysWithValues: baTalks.map { ($0.id, $0.lastTs) })
            talkNotifyPrimed = primeNotifyTs(&talkNotifyTs, kind: "baTalk", currentTs: current)
            guard talkNotifyPrimed else { return }
        }
        for t in baTalks {
            let prev = talkNotifyTs[t.id] ?? "" // 基準が無いトーク(前回起動後に作られた)は新着扱い
            talkNotifyTs[t.id] = t.lastTs
            guard t.lastTs > prev else { continue }
            guard t.lastTs > (t.reads[myUid()] ?? "") else { continue } // 既読済み(自分が最後に送った場合も)は通知不要
            guard t.memberUids.contains(myUid()), t.memberUids.count > 1 else { continue } // メモは対象外
            guard currentBaTalkId != t.id else { continue } // 開いているトークは通知不要
            addNotification(kind: "baTalk", targetId: t.id,
                            title: "BAチャット: \(baTalkName(t))",
                            body: snippet(t.lastText, 60))
        }
        UserDefaults.standard.set(talkNotifyTs, forKey: notifyTsKey("baTalk"))
    }

    /// トークごとの未読数を数える(自分の既読時刻より後の、自分・システム以外のメッセージ)
    private func refreshTalkUnreadCounts() {
        guard isExpert else { return }
        talkUnreadGeneration += 1
        let gen = talkUnreadGeneration
        for t in baTalks where t.memberUids.contains(myUid()) {
            // 開いているトークはその場で読んでいるので常に0
            if t.id == currentBaTalkId {
                if talkUnread[t.id] != 0 { talkUnread[t.id] = 0 }
                continue
            }
            // 後から追加されたメンバーは、見える範囲(historyFrom以降)だけを数える
            let myRead = max(t.reads[myUid()] ?? "", t.historyFrom[myUid()] ?? "")
            // 最終メッセージまで既読なら0(メモも対象外)
            if t.lastTs.isEmpty || t.lastTs <= myRead || t.memberUids.count <= 1 {
                if talkUnread[t.id] != 0 { talkUnread[t.id] = 0 }
                continue
            }
            let ref = wsRef().collection("baTalks").document(t.id).collection("messages")
            let query: Query = myRead.isEmpty ? ref : ref.whereField("ts", isGreaterThan: myRead)
            query.getDocuments { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, gen == self.talkUnreadGeneration else { return }
                    let count = snap?.documents.filter { d in
                        let sender = d.data()["senderUid"] as? String ?? ""
                        let deleted = d.data()["deleted"] as? Bool ?? false
                        return !deleted && sender != self.myUid() && sender != "system"
                    }.count ?? 0
                    if self.talkUnread[t.id] != count { self.talkUnread[t.id] = count }
                }
            }
        }
    }

    private func addNotification(kind: String, targetId: String, title: String, body: String) {
        let n = AppNotification(id: newUid(), ts: nowIso(), kind: kind,
                                targetId: targetId, title: title, body: body, read: false)
        notifications.insert(n, at: 0)
        if notifications.count > 100 { notifications = Array(notifications.prefix(100)) }
        saveNotifications()
    }

    /// 通知をタップして該当画面を開く(既読にする)
    func openNotification(_ n: AppNotification) {
        markNotificationRead(n.id)
        if n.kind == "room" {
            guard rooms.contains(where: { $0.id == n.targetId }) else { return }
            activeTab = .chat
            openRoom(n.targetId)
        } else {
            guard baTalks.contains(where: { $0.id == n.targetId }) else { return }
            activeTab = .baChat
            openBaTalk(n.targetId)
        }
    }

    func markNotificationRead(_ id: String) {
        if let i = notifications.firstIndex(where: { $0.id == id }) {
            notifications[i].read = true
            saveNotifications()
        }
    }

    func markAllNotificationsRead() {
        notifications = notifications.map { var n = $0; n.read = true; return n }
        saveNotifications()
    }

    func deleteNotification(_ id: String) {
        notifications.removeAll { $0.id == id }
        saveNotifications()
    }

    private func notificationsKey() -> String { "appNotifications-\(myUid())" }

    func loadNotifications() {
        guard let data = UserDefaults.standard.data(forKey: notificationsKey()),
              let list = try? JSONDecoder().decode([AppNotification].self, from: data) else {
            notifications = []
            return
        }
        notifications = list
    }

    private func saveNotifications() {
        if let data = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(data, forKey: notificationsKey())
        }
    }

    /// ニックネームを保存(過去の担当記録・送信者名も新名に書き換える)
    func saveNickname(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != nickname, let uid = user?.uid else { return }
        let oldName = myName()
        nickname = trimmed
        wsRef().collection("members").document(uid)
            .setData(["nickname": trimmed], merge: true)
        guard oldName != trimmed else { return }
        Task { await renameInRecords(from: oldName, to: trimmed, uid: uid) }
    }

    /// 旧名で記録されている担当・送信者名を一括で新名に書き換える
    private func renameInRecords(from oldName: String, to newName: String, uid: String) async {
        let ws = wsRef()
        // 相談の担当
        if let snap = try? await ws.collection("rooms")
            .whereField("handler", isEqualTo: oldName).getDocuments() {
            for doc in snap.documents {
                try? await doc.reference.setData(["handler": newName], merge: true)
            }
        }
        // 案件の対応者
        if let snap = try? await ws.collection("cases")
            .whereField("handledBy", isEqualTo: oldName).getDocuments() {
            for doc in snap.documents {
                try? await doc.reference.setData(["handledBy": newName], merge: true)
            }
        }
        // 相談チャットの自分のメッセージの送信者名
        if let rooms = try? await ws.collection("rooms").getDocuments() {
            for room in rooms.documents {
                if let msgs = try? await room.reference.collection("messages")
                    .whereField("senderName", isEqualTo: oldName).getDocuments() {
                    for m in msgs.documents {
                        try? await m.reference.setData(["senderName": newName], merge: true)
                    }
                }
            }
        }
        // BAトークのメンバー名と自分のメッセージの送信者名
        if let talks = try? await ws.collection("baTalks")
            .whereField("memberUids", arrayContains: uid).getDocuments() {
            for talk in talks.documents {
                let uids = talk.data()["memberUids"] as? [String] ?? []
                var names = talk.data()["memberNames"] as? [String] ?? []
                if let i = uids.firstIndex(of: uid), i < names.count, names[i] == oldName {
                    names[i] = newName
                    try? await talk.reference.setData(["memberNames": names], merge: true)
                }
                if let msgs = try? await talk.reference.collection("messages")
                    .whereField("senderUid", isEqualTo: uid).getDocuments() {
                    for m in msgs.documents where (m.data()["senderName"] as? String) == oldName {
                        try? await m.reference.setData(["senderName": newName], merge: true)
                    }
                }
            }
        }
    }

    /// アイコン(絵文字)を保存(画像アイコンは解除)
    func saveIcon(_ emoji: String) {
        myIcon = emoji
        myIconData = ""
        guard let uid = user?.uid else { return }
        wsRef().collection("members").document(uid)
            .setData(["icon": emoji, "iconData": FieldValue.delete()], merge: true)
    }

    /// アイコン画像(JPEG)を保存
    func saveIconImage(_ data: Data) {
        guard data.count <= 100_000, let uid = user?.uid else { return }
        myIconData = data.base64EncodedString()
        wsRef().collection("members").document(uid)
            .setData(["iconData": myIconData], merge: true)
    }

    private struct IconSpec: Decodable {
        let emoji: String
        let colorTop: String
        let colorBottom: String
    }

    /// イメージの説明文からアイコンの構成(絵文字+背景グラデーション)をAIで生成する
    func generateIconSpec(from description: String) async throws -> (emoji: String, top: String, bottom: String) {
        let raw = try await ClaudeService.call(
            system: Prompts.iconGenSystem,
            messages: [.init(role: "user", content: "アイコンのイメージ: \(description)")],
            schema: Prompts.iconGenSchema
        )
        let spec = try JSONDecoder().decode(IconSpec.self, from: Data(raw.utf8))
        return (spec.emoji, spec.colorTop, spec.colorBottom)
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

        // 組織の選択肢(会社・部署・担当)
        listeners.append(wsRef().collection("config").document("org").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, let d = snap?.data() else { return }
                func stringMap(_ v: Any?) -> [String: [String]] {
                    guard let raw = v as? [String: Any] else { return [:] }
                    var m: [String: [String]] = [:]
                    for (k, arr) in raw { m[k] = (arr as? [Any])?.compactMap { $0 as? String } ?? [] }
                    return m
                }
                if let c = d["companies"] as? [String], !c.isEmpty { self.orgCompanies = c }
                let dep = stringMap(d["departments"])
                if !dep.isEmpty { self.orgDepartments = dep }
                var sec = stringMap(d["sections"])
                if !sec.isEmpty {
                    // 旧形式(部署のみのキー)は「会社|部署」に展開して読み込む
                    if !sec.keys.contains(where: { $0.contains("|") }) {
                        var expanded: [String: [String]] = [:]
                        for c in self.orgCompanies {
                            for dept in self.orgDepartments[c] ?? [] {
                                if let list = sec[dept] { expanded[Self.sectionKey(c, dept)] = list }
                            }
                        }
                        sec = expanded
                    }
                    self.orgSections = sec
                }
                self.cacheOrgConfig()
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
                self?.detectRoomNotifications()
                self?.backfillRoomHandlers()
            }
        })

        // エスカレーション案件
        listeners.append(wsRef().collection("cases").order(by: "askedAt").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.cases = snap?.documents.compactMap { CaseItem(dict: $0.data()) } ?? []
                self?.backfillRoomHandlers()
                self?.devMaybeReply() // 案件が回答済みになったタイミングでも担当者役の返信を判定
            }
        })

        // Q&Aログ(ダウンロード用)
        listeners.append(wsRef().collection("qa").order(by: "answered_at").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.qaLog = snap?.documents.map { QaEntry(dict: $0.data()) } ?? []
            }
        })

        // BAトーク一覧(財務同士のトークルーム)
        listeners.append(wsRef().collection("baTalks").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.baTalks = snap?.documents.compactMap { BaTalk(dict: $0.data()) } ?? []
                self?.detectTalkNotifications()
                self?.refreshTalkUnreadCounts()
            }
        })

        // メンバー一覧(BAへの対応依頼の宛先に使う)
        listeners.append(wsRef().collection("members").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                self?.members = snap?.documents.map { d in
                    let data = d.data()
                    let nickname = data["nickname"] as? String ?? ""
                    let email = data["email"] as? String ?? ""
                    return MemberInfo(id: d.documentID,
                                      name: nickname.isEmpty ? email : nickname,
                                      role: data["role"] as? String ?? "",
                                      icon: data["icon"] as? String ?? "",
                                      iconData: data["iconData"] as? String ?? "",
                                      email: email,
                                      companies: data["companies"] as? [String]
                                          ?? [(data["company"] as? String ?? "")].filter { !$0.isEmpty },
                                      department: data["department"] as? String ?? "",
                                      section: data["section"] as? String ?? "",
                                      position: data["position"] as? String ?? "")
                } ?? []
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
        var lastText = msg.role == .expert ? "【BA】" + msg.text : msg.text
        if msg.text.isEmpty, let type = msg.attachmentType {
            lastText = type == "image" ? "📷 写真" : "📎 \(msg.attachmentName ?? "ファイル")"
        }
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

    /// メッセージを削除する(ソフトデリート)。本文を退避して「削除されました」表示にし、後から復元できる
    func deleteMessage(_ msg: Message) {
        guard let roomId = currentRoomId, !msg.deleted else { return }
        let roomRef = wsRef().collection("rooms").document(roomId)
        roomRef.collection("messages").document(msg.id).updateData([
            "text": "削除されました",
            "deleted": true,
            "deletedText": msg.text,
        ])
        if roomMessages.last?.id == msg.id {
            roomRef.updateData(["lastText": "削除されました"])
        }
    }

    /// 削除したメッセージを元に戻す
    func restoreMessage(_ msg: Message) {
        guard let roomId = currentRoomId, msg.deleted, let original = msg.deletedText else { return }
        let roomRef = wsRef().collection("rooms").document(roomId)
        roomRef.collection("messages").document(msg.id).updateData([
            "text": original,
            "deleted": FieldValue.delete(),
            "deletedText": FieldValue.delete(),
        ])
        if roomMessages.last?.id == msg.id {
            let lastText = msg.role == .expert ? "【BA】" + original : original
            roomRef.updateData(["lastText": lastText])
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

    /// 対応者のトグル(自分が対応者なら外す、そうでなければ自分を設定)。
    /// 自分を設定したときは相談の担当BAも未設定なら自分にする
    func toggleHandler(_ c: CaseItem) {
        let me = myName()
        guard !me.isEmpty else { return }
        let becoming = c.handledBy != me
        updateCase(c.id, ["handledBy": becoming ? me : ""])
        if becoming, let r = rooms.first(where: { $0.id == c.roomId }), r.handler.isEmpty {
            setRoomHandler(c.roomId, handler: me)
        }
    }

    /// 相談の担当BAを設定/解除する(AIだけで完結した相談にも割り当て可能)
    func setRoomHandler(_ roomId: String, handler: String) {
        wsRef().collection("rooms").document(roomId).updateData(["handler": handler])
    }

    /// 案件から推定できる担当(未回答案件の対応者 → 最新の回答済み案件の対応者)
    func derivedHandler(roomId: String) -> String {
        if let open = cases.first(where: { $0.roomId == roomId && $0.status != .answered && !$0.handledBy.isEmpty }) {
            return open.handledBy
        }
        return cases
            .filter { $0.roomId == roomId && $0.status == .answered && !$0.handledBy.isEmpty }
            .last?.handledBy ?? ""
    }

    private var backfilledRoomIds: Set<String> = []
    private var backfilledCaseIds: Set<String> = []

    /// 担当BAが未設定の相談に、案件から推定した担当を書き戻す。
    /// 逆に、相談の担当BAが決まっているのに未回答案件の対応者が空なら揃える。
    /// これにより一覧・チャットとも同じ担当が表示される
    func backfillRoomHandlers() {
        guard isExpert else { return }
        for r in rooms where r.handler.isEmpty && !backfilledRoomIds.contains(r.id) {
            let derived = derivedHandler(roomId: r.id)
            if !derived.isEmpty {
                backfilledRoomIds.insert(r.id)
                setRoomHandler(r.id, handler: derived)
            }
        }
        for c in cases where c.status != .answered && c.handledBy.isEmpty && !backfilledCaseIds.contains(c.id) {
            if let r = rooms.first(where: { $0.id == c.roomId }), !r.handler.isEmpty {
                backfilledCaseIds.insert(c.id)
                updateCase(c.id, ["handledBy": r.handler])
            }
        }
    }

    /// 相談の担当BAのトグル(自分なら外す、そうでなければ自分に)。
    func toggleRoomHandler(_ roomId: String) {
        let me = myName()
        guard !me.isEmpty, isExpert,
              let r = rooms.first(where: { $0.id == roomId }) else { return }
        let current = r.handler.isEmpty ? derivedHandler(roomId: roomId) : r.handler
        assignRoomHandler(roomId, to: current == me ? "" : me)
    }

    /// 相談の担当BAを指定の人に割り当てる(他のBAへの対応依頼にも使う)。
    /// 未回答案件の対応者も連動して同じ担当に揃える
    func assignRoomHandler(_ roomId: String, to handler: String) {
        guard isExpert else { return }
        setRoomHandler(roomId, handler: handler)
        for c in cases where c.roomId == roomId && c.status != .answered {
            updateCase(c.id, ["handledBy": handler])
        }
        guard !handler.isEmpty else { return }
        // 担当が付いたら、待機案内を消してAI回答待ちだった質問への回答を開始する
        removeHandlerWaitNotices(roomId)
        if handler != myName() {
            // 他のBAへの依頼はチャットに記録して相手にも分かるようにする(財務のみ表示)
            addMessage(Message(role: .system,
                               text: "\(myName())さんが\(handler)さんに対応を依頼しました。",
                               expertOnly: true), roomId: roomId)
        }
        triggerPendingTriage(roomId)
    }

    static let handlerWaitNotice = "担当BAが割り当てられると、AIアシスタントが回答します。しばらくお待ちください。"

    /// 担当BAの割り当て待ち案内を相談から削除する
    private func removeHandlerWaitNotices(_ roomId: String) {
        guard currentRoomId == roomId else { return }
        let roomRef = wsRef().collection("rooms").document(roomId)
        for m in roomMessages where m.role == .system && m.text == Self.handlerWaitNotice {
            roomRef.collection("messages").document(m.id).delete()
        }
    }

    /// 担当BA待ちで止まっていた質問があれば、AIのトリアージを実行する
    private func triggerPendingTriage(_ roomId: String) {
        guard currentRoomId == roomId, !sending,
              let last = roomMessages.last(where: { !$0.deleted && $0.role != .system }),
              last.role == .user else { return }
        Task { [weak self] in
            guard let self, !self.sending else { return }
            self.sending = true
            self.pendingTyping = true
            defer {
                self.pendingTyping = false
                self.sending = false
            }
            await self.runTriage(text: last.text, roomId: roomId)
        }
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

    /// よく使うリアクション絵文字(Teams風)
    static let reactionEmojis = ["👍", "❤️", "😂", "😮", "🙏", "👏"]

    /// 相談チャットのメッセージへのリアクションをトグルする
    func toggleReaction(_ msg: Message, emoji: String) {
        guard let uid = user?.uid, let roomId = currentRoomId else { return }
        let ref = wsRef().collection("rooms").document(roomId)
            .collection("messages").document(msg.id)
        if (msg.reactions[emoji] ?? []).contains(uid) {
            ref.updateData(["reactions.\(emoji)": FieldValue.arrayRemove([uid])])
        } else {
            ref.updateData(["reactions.\(emoji)": FieldValue.arrayUnion([uid])])
        }
    }

    /// BAトークのメッセージへのリアクションをトグルする
    func toggleBaReaction(_ msg: BaMessage, emoji: String) {
        guard let uid = user?.uid, let talkId = currentBaTalkId else { return }
        let ref = wsRef().collection("baTalks").document(talkId)
            .collection("messages").document(msg.id)
        if (msg.reactions[emoji] ?? []).contains(uid) {
            ref.updateData(["reactions.\(emoji)": FieldValue.arrayRemove([uid])])
        } else {
            ref.updateData(["reactions.\(emoji)": FieldValue.arrayUnion([uid])])
        }
    }

    /// 相談チャットに添付(写真/ファイル)を送る。AIのトリアージは行わない
    func sendRoomAttachment(data: Data, name: String, type: String) {
        guard currentRoomId != nil, canSendInCurrentRoom, data.count <= 600_000 else { return }
        addMessage(Message(role: .user, text: "",
                           senderName: myName(),
                           attachmentType: type,
                           attachmentName: name,
                           attachmentData: data.base64EncodedString()))
    }

    // MARK: - BAトーク(財務同士のトークルーム)

    /// 自分が参加しているトーク(自分が固定したものを先頭に。固定分は保存した並び順)
    var myBaTalks: [BaTalk] {
        let uid = myUid()
        func pinIndex(_ t: BaTalk) -> Int {
            pinnedTalkOrder.firstIndex(of: t.id) ?? Int.max
        }
        return baTalks
            .filter { $0.memberUids.contains(uid) }
            .sorted { a, b in
                let ap = a.pinnedBy.contains(uid), bp = b.pinnedBy.contains(uid)
                if ap != bp { return ap }
                if ap && bp {
                    let ia = pinIndex(a), ib = pinIndex(b)
                    if ia != ib { return ia < ib }
                }
                return a.lastTs > b.lastTs
            }
    }

    /// ピン留めトークの並び替え(長押しドラッグ)。並び順はアカウントごとに保存
    func movePinnedTalks(current: [BaTalk], from: IndexSet, to: Int) {
        var ids = current.map { $0.id }
        ids.move(fromOffsets: from, toOffset: to)
        pinnedTalkOrder = ids
        guard let uid = user?.uid else { return }
        wsRef().collection("members").document(uid)
            .setData(["pinnedTalkOrder": ids], merge: true)
    }

    /// トークの上部固定のトグル(自分の表示にのみ影響)
    func toggleBaTalkPin(_ id: String) {
        guard let uid = user?.uid, let t = baTalks.first(where: { $0.id == id }) else { return }
        let ref = wsRef().collection("baTalks").document(id)
        if t.pinnedBy.contains(uid) {
            ref.updateData(["pinnedBy": FieldValue.arrayRemove([uid])])
        } else {
            ref.updateData(["pinnedBy": FieldValue.arrayUnion([uid])])
        }
    }

    /// トークを削除する(メッセージごと。全員の一覧から消える)
    func deleteBaTalk(_ id: String) async {
        let ref = wsRef().collection("baTalks").document(id)
        if let msgs = try? await ref.collection("messages").getDocuments() {
            for d in msgs.documents { try? await d.reference.delete() }
        }
        try? await ref.delete()
        if currentBaTalkId == id { closeBaTalk() }
    }

    /// トークの表示名。グループ・メモは「名前 (参加人数)」で表示。1:1は相手の名前
    func baTalkName(_ t: BaTalk) -> String {
        if t.memberUids.count <= 1 {
            let base = t.name.isEmpty ? "📝 メモ" : t.name
            return "\(base) (\(max(t.memberUids.count, 1)))"
        }
        if t.isGroup {
            let base = t.name.isEmpty ? t.memberNames.joined(separator: "、") : t.name
            return "\(base) (\(t.memberUids.count))"
        }
        // 1:1でもルーム名を付けていればそれを表示
        if !t.name.isEmpty { return t.name }
        return t.memberNames.first { $0 != myName() } ?? t.memberNames.joined(separator: "、")
    }

    func openBaTalk(_ id: String) {
        currentBaTalkId = id
        if talkUnread[id] != 0 { talkUnread[id] = 0 } // 既読の書き込みを待たずにバッジを消す
        subscribeBaTalkMessages(id)
        if baTalkPath != [id] { baTalkPath = [id] }
    }

    func backToBaTalks() {
        closeBaTalk()
    }

    func handleBaTalkPathChange() {
        // 相談リンクで開いていた相談が閉じられたら、相談側の状態だけ後始末する
        if !baTalkPath.contains(where: { $0.hasPrefix("room:") }),
           currentRoomId != nil, chatPath.isEmpty {
            pendingRoom = nil
            currentRoomId = nil
            stopRoomMessages()
            roomMessages = []
        }
        if baTalkPath.isEmpty, currentBaTalkId != nil { closeBaTalk() }
    }

    private func closeBaTalk() {
        currentBaTalkId = nil
        baTalkMsgListener?.remove()
        baTalkMsgListener = nil
        baTalkMessages = []
        if !baTalkPath.isEmpty { baTalkPath = [] }
    }

    private func subscribeBaTalkMessages(_ id: String) {
        baTalkMsgListener?.remove()
        baTalkMessages = []
        baTalkMsgListener = wsRef().collection("baTalks").document(id).collection("messages")
            .order(by: "ts").addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    self?.baTalkMessages = snap?.documents.compactMap { BaMessage(dict: $0.data()) } ?? []
                    self?.markBaTalkRead()
                }
            }
    }

    /// 開いているトークのメッセージを既読にする
    private func markBaTalkRead() {
        guard let uid = user?.uid, let talkId = currentBaTalkId,
              let talk = baTalks.first(where: { $0.id == talkId }),
              let lastTs = baTalkMessages.last?.ts, !lastTs.isEmpty else { return }
        let current = talk.reads[uid] ?? ""
        guard lastTs > current else { return }
        wsRef().collection("baTalks").document(talkId).updateData(["reads.\(uid)": lastTs])
    }

    /// トークを開始する。selectedが空=自分だけのメモ / 1人=1:1(既存があれば再利用) / 2人以上=グループ
    func startBaTalk(with selected: [MemberInfo], groupName: String = "") -> String {
        let all = [MemberInfo(id: myUid(), name: myName(), role: MemberRole.expert.rawValue)] + selected
        let uids = all.map { $0.id }.sorted()
        let isGroup = selected.count > 1
        let talkId: String
        if selected.count == 1 {
            talkId = "dm_" + uids.joined(separator: "_") // 1:1は同じ相手と1つだけ
        } else {
            talkId = newUid() // メモ・グループは複数作れる
        }
        let name = selected.isEmpty
            ? (groupName.isEmpty ? "メモ" : groupName)
            : groupName.trimmingCharacters(in: .whitespaces)
        if !baTalks.contains(where: { $0.id == talkId }) {
            let talk = BaTalk(id: talkId,
                              name: name,
                              memberUids: uids,
                              memberNames: all.map { $0.name },
                              isGroup: isGroup)
            wsRef().collection("baTalks").document(talkId).setData(talk.dict)
        } else if !name.isEmpty {
            // 既存の1:1トークでもルーム名の指定があれば反映する
            renameBaTalk(talkId, name: name)
        }
        return talkId
    }

    /// トークのルーム名を変更する(グループ・メモ・1:1すべて)
    func renameBaTalk(_ id: String, name: String) {
        guard isExpert, baTalks.contains(where: { $0.id == id }) else { return }
        wsRef().collection("baTalks").document(id)
            .updateData(["name": name.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    /// 開いているトークにメッセージを送る(roomId=相談リンク / attachment=写真・ファイル添付)
    func sendBaTalkMessage(_ text: String, roomId: String? = nil, roomTitle: String? = nil,
                           attachmentData: Data? = nil, attachmentName: String? = nil, attachmentType: String? = nil) {
        var text = text, roomId = roomId, roomTitle = roomTitle
        // 相談チャットでコピーしたリンク(chatbotwest://room/…)が貼られていたらリンクカードに変換する
        if roomId == nil, let range = text.range(of: #"chatbotwest://room/[A-Za-z0-9_-]+"#, options: .regularExpression) {
            let id = String(text[range].dropFirst("chatbotwest://room/".count))
            if let room = rooms.first(where: { $0.id == id }) {
                roomId = room.id
                roomTitle = room.title
                text.removeSubrange(range)
            }
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isExpert, let talkId = currentBaTalkId,
              !t.isEmpty || roomId != nil || attachmentData != nil else { return }
        if let d = attachmentData, d.count > 600_000 { return }
        let msg = BaMessage(text: t, senderUid: myUid(), senderName: myName(),
                            roomId: roomId, roomTitle: roomTitle,
                            attachmentType: attachmentData != nil ? attachmentType : nil,
                            attachmentName: attachmentName,
                            attachmentData: attachmentData?.base64EncodedString())
        let talkRef = wsRef().collection("baTalks").document(talkId)
        talkRef.collection("messages").document(msg.id).setData(msg.dict)
        var preview = t
        if preview.isEmpty {
            if roomId != nil { preview = "🔗 \(roomTitle?.isEmpty == false ? roomTitle! : "相談")" }
            else if attachmentType == "image" { preview = "📷 写真" }
            else if attachmentData != nil { preview = "📎 \(attachmentName ?? "ファイル")" }
        }
        talkRef.setData(["lastText": preview, "lastTs": msg.ts], merge: true)
    }

    /// トークにメンバーを追加する。showHistory=false なら追加メンバーには追加時点以降の履歴だけ見せる
    func addBaTalkMembers(_ talkId: String, members newMembers: [MemberInfo], showHistory: Bool) {
        guard isExpert, !newMembers.isEmpty,
              let talk = baTalks.first(where: { $0.id == talkId }) else { return }
        let ref = wsRef().collection("baTalks").document(talkId)
        var updates: [String: Any] = [
            "memberUids": FieldValue.arrayUnion(newMembers.map { $0.id }),
            "memberNames": FieldValue.arrayUnion(newMembers.map { $0.name }),
        ]
        if talk.memberUids.count + newMembers.count > 2 {
            updates["isGroup"] = true // 1:1に追加したらグループになる
        }
        if !showHistory {
            for m in newMembers { updates["historyFrom.\(m.id)"] = nowIso() }
        }
        ref.updateData(updates)
        // 追加をトーク内に記録
        let names = newMembers.map { $0.name }.joined(separator: "、")
        let notice = BaMessage(text: "\(myName())さんが\(names)さんを追加しました。",
                               senderUid: "system", senderName: "")
        ref.collection("messages").document(notice.id).setData(notice.dict)
        ref.setData(["lastText": notice.text, "lastTs": notice.ts], merge: true)
    }

    /// BAトークのメッセージ本文を編集する(自分のメッセージのみ)
    func updateBaMessageText(_ msg: BaMessage, newText: String) {
        guard let talkId = currentBaTalkId, msg.senderUid == myUid() else { return }
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != msg.text else { return }
        let talkRef = wsRef().collection("baTalks").document(talkId)
        talkRef.collection("messages").document(msg.id).updateData(["text": text])
        if baTalkMessages.last?.id == msg.id {
            talkRef.setData(["lastText": text], merge: true)
        }
    }

    /// BAトークのメッセージを削除する(ソフトデリート・復元可能)
    func deleteBaMessage(_ msg: BaMessage) {
        guard let talkId = currentBaTalkId, msg.senderUid == myUid(), !msg.deleted else { return }
        let talkRef = wsRef().collection("baTalks").document(talkId)
        talkRef.collection("messages").document(msg.id).updateData([
            "text": "削除されました",
            "deleted": true,
            "deletedText": msg.text,
        ])
        if baTalkMessages.last?.id == msg.id {
            talkRef.setData(["lastText": "削除されました"], merge: true)
        }
    }

    /// 削除したBAトークのメッセージを元に戻す
    func restoreBaMessage(_ msg: BaMessage) {
        guard let talkId = currentBaTalkId, msg.senderUid == myUid(),
              msg.deleted, let original = msg.deletedText else { return }
        let talkRef = wsRef().collection("baTalks").document(talkId)
        talkRef.collection("messages").document(msg.id).updateData([
            "text": original,
            "deleted": FieldValue.delete(),
            "deletedText": FieldValue.delete(),
        ])
        if baTalkMessages.last?.id == msg.id {
            talkRef.setData(["lastText": original], merge: true)
        }
    }

    // MARK: - BAチャット全体の検索(キーワード+意味検索)

    struct BaSearchResult: Identifiable {
        let id: String
        let talkId: String
        let talkName: String
        let senderName: String
        let text: String
        let ts: String
    }

    private struct BaSearchMatches: Decodable {
        let matches: [String]
    }

    /// トークを検索する(talkId指定でそのトーク内のみ、省略で自分の全トーク)。
    /// 部分一致に加え、AIによる意味の近いメッセージも返す
    func searchBaTalks(query: String, in talkId: String? = nil) async throws -> [BaSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var corpus: [BaSearchResult] = []
        let targets = talkId == nil ? myBaTalks : myBaTalks.filter { $0.id == talkId }
        for talk in targets {
            let snap = try await wsRef().collection("baTalks").document(talk.id)
                .collection("messages").order(by: "ts", descending: true).limit(to: 100).getDocuments()
            let from = talk.historyFrom[myUid()]
            for d in snap.documents {
                guard let m = BaMessage(dict: d.data()), !m.text.isEmpty, !m.deleted else { continue }
                if let from, m.ts < from { continue } // 自分に見せない履歴は検索にも出さない
                corpus.append(BaSearchResult(id: m.id, talkId: talk.id, talkName: baTalkName(talk),
                                             senderName: m.senderName, text: m.text, ts: m.ts))
            }
        }
        guard !corpus.isEmpty else { return [] }
        // 1) キーワードの部分一致
        let local = corpus.filter { $0.text.localizedCaseInsensitiveContains(q) }
        // 2) AIによる意味検索
        var semanticIds: [String] = []
        let numbered = corpus.prefix(300)
            .map { "\($0.id): \(String($0.text.prefix(80)))" }
            .joined(separator: "\n")
        if let raw = try? await ClaudeService.call(
            system: Prompts.baSearchSystem,
            messages: [.init(role: "user", content: "検索ワード: \(q)\n\nメッセージ一覧(ID: 本文):\n\(numbered)")],
            schema: Prompts.baSearchSchema
        ), let decoded = try? JSONDecoder().decode(BaSearchMatches.self, from: Data(raw.utf8)) {
            semanticIds = decoded.matches
        }
        let semantic = corpus.filter { semanticIds.contains($0.id) }
        var seen = Set<String>()
        var results: [BaSearchResult] = []
        for r in local + semantic where !seen.contains(r.id) {
            seen.insert(r.id)
            results.append(r)
        }
        return results.sorted { $0.ts > $1.ts }
    }

    /// トークの相談リンクから相談チャットを開く
    /// BAチャットのリンクから相談を開く。BAチャットのスタックに積むので、
    /// 戻るスワイプの背後には元のBAトークが見える
    func openRoomFromBaChat(_ roomId: String) {
        guard rooms.contains(where: { $0.id == roomId }) else { return }
        pendingRoom = nil
        currentRoomId = roomId
        subscribeRoomMessages(roomId)
        if baTalkPath.last != "room:\(roomId)" {
            baTalkPath.append("room:\(roomId)")
        }
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
        // 送信者名: 通常は自分、開発モードの担当者役は相談の本人の名前
        let senderName = simulated
            ? (currentRoom().map { $0.ownerName.isEmpty ? $0.ownerEmail : $0.ownerName } ?? "")
            : myName()
        addMessage(Message(role: .user, text: text, senderName: senderName))

        defer {
            pendingTyping = false
            sending = false
        }

        // 担当BAが決まるまでAIは回答しない(担当が付いた時点で回答が始まる)
        let handler = currentRoom().map { $0.handler.isEmpty ? derivedHandler(roomId: $0.id) : $0.handler } ?? ""
        if handler.isEmpty {
            pendingTyping = false
            if !roomMessages.contains(where: { $0.role == .system && $0.text == Self.handlerWaitNotice }) {
                addMessage(Message(role: .system, text: Self.handlerWaitNotice), roomId: roomId)
            }
            return
        }

        await runTriage(text: text, roomId: roomId)
    }

    /// 直近のユーザー質問に対してAIのトリアージ(回答/聞き返し/エスカレーション)を実行する
    private func runTriage(text: String, roomId: String) async {
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
                // この相談で最初に対応した人(いなければ相談の担当BA)をデフォルトの対応者として引き継ぐ
                let defaultHandler = cases
                    .filter { $0.roomId == roomId && !$0.handledBy.isEmpty }
                    .first?.handledBy
                    ?? rooms.first { $0.id == roomId }?.handler
                    ?? ""
                let caseObj = CaseItem(
                    roomId: roomId,
                    question: text,
                    reason: result.escalation_reason.isEmpty ? "専門家の確認が必要な質問です。" : result.escalation_reason,
                    options: result.options.isEmpty ? ["質問内容を確認のうえ個別に回答する"] : result.options,
                    handledBy: defaultHandler
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
        addMessage(Message(role: .expert, text: text, senderName: handler), roomId: c.roomId)
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
        // 回答したBAを相談の担当にする(未設定の場合)
        if let r = rooms.first(where: { $0.id == c.roomId }), r.handler.isEmpty, !handler.isEmpty {
            setRoomHandler(c.roomId, handler: handler)
        }
    }

    /// 開いている相談のこれまでのやり取りを要約する
    func summarizeCurrentRoom() async throws -> String {
        let transcript = roomMessages
            .filter { $0.role != .system && !$0.deleted }
            .map { m -> String in
                switch m.role {
                case .user: return "質問者: \(m.text)"
                case .ai: return "AIアシスタント: \(m.text)"
                case .expert: return "BA(専門家): \(m.text)"
                case .system: return ""
                }
            }
            .joined(separator: "\n\n")
        guard !transcript.isEmpty else {
            throw ClaudeService.ClaudeError.server("この相談にはまだやり取りがありません。")
        }
        let summary = try await ClaudeService.call(
            system: Prompts.summarySystem,
            messages: [.init(role: "user", content: "以下の会計相談チャットのやり取りを要約してください。\n\n\(transcript)")]
        )
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 開発モード(APIによる担当者役)

    /// 開いている相談が「担当者の返答待ち」の状態なら、担当者役の返信をスケジュールする。
    /// メッセージ・案件の更新のたびに呼ばれるため、既存の「担当者回答待ち」の相談を開いたときも動く。
    private func devMaybeReply() {
        guard devMode, let roomId = currentRoomId else { return }
        // 削除済み・システムメッセージは無視して、最後の実質的なメッセージを見る
        guard let last = roomMessages.last(where: { !$0.deleted && $0.role != .system }) else { return }
        guard last.role == .ai || last.role == .expert else { return }
        guard !devRepliedMsgIds.contains(last.id), !isDoneRoom(roomId) else { return }
        // 未回答の案件がある(=BA回答待ち)ときはBAの回答を待つ
        guard !cases.contains(where: { $0.roomId == roomId && $0.status != .answered }) else { return }
        let isClarify = last.role == .ai && !last.clarifyOptions.isEmpty
        scheduleDevQuestionerReply(roomId: roomId, isFollowup: !isClarify, msgId: last.id)
    }

    /// APIが担当者役(会計の素人)として返信する。
    /// 聞き返しには返答し、AI/BAの回答には納得するまで更問をする。
    /// 納得した場合(または更問の上限に達した場合)はお礼を送って相談を完了にする。
    /// 途中で中断・失敗した場合は返信済みマークを外し、次のスナップショット更新で再試行できるようにする。
    private func scheduleDevQuestionerReply(roomId: String, isFollowup: Bool, msgId: String) {
        guard devMode else { return }
        let followupLimitReached = isFollowup && devFollowupCounts[roomId, default: 0] >= devReplyLimit
        if !isFollowup, devClarifyCounts[roomId, default: 0] >= devReplyLimit { return }
        devRepliedMsgIds.insert(msgId) // 二重予約を防ぐ(失敗時は外して再試行可能にする)

        Task { [weak self] in
            // 即答: 待機はスナップショットの反映を待つ最小限だけ
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            let retryLater = { self.devRepliedMsgIds.remove(msgId) }
            // オフにされた/相談を閉じた/送信中 → いったん取り下げ(条件が揃えば再試行される)
            guard self.devMode, self.currentRoomId == roomId, !self.sending else { retryLater(); return }

            if followupLimitReached {
                // 更問の上限に達したら、納得したことにしてお礼+完了
                self.devFinishRoom(roomId, thanks: "ありがとうございます、よく分かりました!")
                return
            }

            // 会話履歴を台本テキストとして1つのメッセージにまとめて渡す
            // (roleを反転して渡すと構造が不正になり、モデルがアーティファクトを出すため)
            let transcript = self.roomMessages
                .filter { $0.role != .system && !$0.deleted }
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
            guard !transcript.isEmpty else { retryLater(); return }
            self.devTypingRoomId = roomId // 「質問者が入力中…」を表示
            defer { if self.devTypingRoomId == roomId { self.devTypingRoomId = nil } }

            // 一時的なAPIエラー(Functionsのタイムアウト等)に備えて最大2回試す
            var raw: String?
            for attempt in 1...2 {
                do {
                    raw = try await ClaudeService.call(
                        system: Prompts.devQuestionerSystem,
                        messages: [.init(role: "user", content: """
                        以下は会計相談チャットのこれまでのやり取りです。あなたは「質問者」です。
                        このやり取りの続きとして、質問者が次に送るメッセージを決めてください。

                        \(transcript)
                        """)],
                        schema: Prompts.devQuestionerSchema
                    )
                    break
                } catch {
                    if attempt == 2 {
                        // 全滅 → マークを外す(相談を開き直すと再試行される)
                        retryLater()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            guard let raw,
                  let result = try? JSONDecoder().decode(DevQuestionerResult.self, from: Data(raw.utf8)) else {
                retryLater()
                return
            }
            let text = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, self.currentRoomId == roomId else { retryLater(); return }
            // 返信を投稿する前に「入力中…」を消す(AIの入力中表示と重ならないように)
            self.devTypingRoomId = nil
            if result.satisfied && isFollowup {
                // 納得した → お礼を送って完了にする
                self.devFinishRoom(roomId, thanks: text)
            } else {
                if isFollowup { self.devFollowupCounts[roomId, default: 0] += 1 }
                else { self.devClarifyCounts[roomId, default: 0] += 1 }
                await self.submitQuestion(text, simulated: true)
            }
        }
    }

    /// 担当者役がお礼を送って相談を完了にする
    private func devFinishRoom(_ roomId: String, thanks: String) {
        let senderName = rooms.first { $0.id == roomId }
            .map { $0.ownerName.isEmpty ? $0.ownerEmail : $0.ownerName } ?? ""
        addMessage(Message(role: .user, text: thanks, senderName: senderName), roomId: roomId)
        if let r = rooms.first(where: { $0.id == roomId }), !r.isDone {
            toggleRoomDone(roomId)
        }
    }
}
