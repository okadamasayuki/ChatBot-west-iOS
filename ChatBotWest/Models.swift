import Foundation

// Web版と同一の Firestore ドキュメント構造を扱うため、
// 日時は ISO8601 文字列、ID は文字列のまま保持する。

func nowIso() -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return fmt.string(from: Date())
}

func newUid() -> String {
    let ts = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    let rand = String((0..<6).map { _ in "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()! })
    return ts + rand
}

func parseIso(_ iso: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fmt.date(from: iso) { return d }
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.date(from: iso)
}

/// トーク一覧のような「今日は時刻、それ以外は月/日」表示
func fmtDate(_ iso: String) -> String {
    guard let d = parseIso(iso) else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "H:mm" : "M/d"
    return f.string(from: d)
}

/// メッセージの時刻表示(Web版 fmtTime: "M/d H:mm")
func fmtTime(_ iso: String) -> String {
    guard let d = parseIso(iso) else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.dateFormat = "M/d H:mm"
    return f.string(from: d)
}

func snippet(_ t: String?, _ n: Int) -> String {
    let s = (t ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return s.count > n ? String(s.prefix(n)) + "…" : s
}

// MARK: - Room(相談)

struct Room: Identifiable, Equatable {
    var id: String
    var title: String
    var createdAt: String
    var lastText: String
    var lastTs: String
    var ownerUid: String
    var ownerEmail: String
    var ownerName: String
    /// "done" = 完了 / それ以外(空)は進行中
    var status: String
    /// 既読管理: uid → そのユーザーが読んだ最後のメッセージの ts
    var reads: [String: String]
    /// この相談の担当BA(表示名)。AIだけで完結した相談にも割り当てられる
    var handler: String
    /// 対応依頼の承諾待ち: 依頼された側のBA(表示名)。承諾すると handler になる
    var pendingHandler: String
    /// 対応依頼をした側のBA(表示名)
    var pendingHandlerBy: String
    /// 直近の対応依頼の結果("accepted" | "declined")。依頼した側への通知に使う
    var handlerRequestResult: String
    var handlerRequestResultBy: String  // 承諾/辞退したBA
    var handlerRequestResultTo: String  // 依頼していたBA(通知の宛先)
    var handlerRequestResultTs: String

    init(id: String = newUid(), title: String = "新しい相談", createdAt: String = nowIso(),
         lastText: String = "", lastTs: String = nowIso(),
         ownerUid: String = "", ownerEmail: String = "", ownerName: String = "", status: String = "",
         reads: [String: String] = [:], handler: String = "",
         pendingHandler: String = "", pendingHandlerBy: String = "") {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.lastText = lastText; self.lastTs = lastTs
        self.ownerUid = ownerUid; self.ownerEmail = ownerEmail; self.ownerName = ownerName
        self.status = status
        self.reads = reads
        self.handler = handler
        self.pendingHandler = pendingHandler
        self.pendingHandlerBy = pendingHandlerBy
        self.handlerRequestResult = ""
        self.handlerRequestResultBy = ""
        self.handlerRequestResultTo = ""
        self.handlerRequestResultTs = ""
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        title = dict["title"] as? String ?? "相談"
        createdAt = dict["createdAt"] as? String ?? ""
        lastText = dict["lastText"] as? String ?? ""
        lastTs = dict["lastTs"] as? String ?? ""
        ownerUid = dict["ownerUid"] as? String ?? ""
        ownerEmail = dict["ownerEmail"] as? String ?? ""
        ownerName = dict["ownerName"] as? String ?? ""
        status = dict["status"] as? String ?? ""
        reads = dict["reads"] as? [String: String] ?? [:]
        handler = dict["handler"] as? String ?? ""
        pendingHandler = dict["pendingHandler"] as? String ?? ""
        pendingHandlerBy = dict["pendingHandlerBy"] as? String ?? ""
        handlerRequestResult = dict["handlerRequestResult"] as? String ?? ""
        handlerRequestResultBy = dict["handlerRequestResultBy"] as? String ?? ""
        handlerRequestResultTo = dict["handlerRequestResultTo"] as? String ?? ""
        handlerRequestResultTs = dict["handlerRequestResultTs"] as? String ?? ""
    }

    var isDone: Bool { status == "done" }

    var dict: [String: Any] {
        var d: [String: Any] = [
            "id": id, "title": title, "createdAt": createdAt,
            "lastText": lastText, "lastTs": lastTs,
            "ownerUid": ownerUid, "ownerEmail": ownerEmail, "ownerName": ownerName,
            "status": status,
        ]
        if !reads.isEmpty { d["reads"] = reads }
        if !handler.isEmpty { d["handler"] = handler }
        if !pendingHandler.isEmpty { d["pendingHandler"] = pendingHandler }
        if !pendingHandlerBy.isEmpty { d["pendingHandlerBy"] = pendingHandlerBy }
        return d
    }
}

// MARK: - Message

enum MessageRole: String {
    case user, ai, expert, system
}

struct Message: Identifiable, Equatable {
    var id: String
    var role: MessageRole
    var text: String
    var ts: String
    var clarifyOptions: [String]
    /// 削除済みフラグ(本文は deletedText に退避され「削除されました」表示になる。復元可能)
    var deleted: Bool
    var deletedText: String?
    /// 送信者の表示名(ニックネーム)。空なら役割ラベルで代替表示
    var senderName: String
    /// 財務(BA)のみに表示するメッセージ(対応依頼の記録など)
    var expertOnly: Bool
    /// 添付("image" | "file")。データはbase64で埋め込む(600KBまで)
    var attachmentType: String?
    var attachmentName: String?
    var attachmentData: String?
    /// リアクション: 絵文字 → 付けたユーザーのuid一覧
    var reactions: [String: [String]]

    init(id: String = newUid(), role: MessageRole, text: String, ts: String = nowIso(),
         clarifyOptions: [String] = [], senderName: String = "", expertOnly: Bool = false,
         attachmentType: String? = nil, attachmentName: String? = nil, attachmentData: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.ts = ts; self.clarifyOptions = clarifyOptions
        self.deleted = false; self.deletedText = nil
        self.senderName = senderName
        self.expertOnly = expertOnly
        self.attachmentType = attachmentType
        self.attachmentName = attachmentName
        self.attachmentData = attachmentData
        self.reactions = [:]
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let roleRaw = dict["role"] as? String else { return nil }
        self.id = id
        role = MessageRole(rawValue: roleRaw) ?? .system
        text = dict["text"] as? String ?? ""
        ts = dict["ts"] as? String ?? ""
        clarifyOptions = dict["clarifyOptions"] as? [String] ?? []
        deleted = dict["deleted"] as? Bool ?? false
        deletedText = dict["deletedText"] as? String
        senderName = dict["senderName"] as? String ?? ""
        expertOnly = dict["expertOnly"] as? Bool ?? false
        attachmentType = dict["attachmentType"] as? String
        attachmentName = dict["attachmentName"] as? String
        attachmentData = dict["attachmentData"] as? String
        reactions = dict["reactions"] as? [String: [String]] ?? [:]
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "role": role.rawValue, "text": text, "ts": ts]
        if !clarifyOptions.isEmpty { d["clarifyOptions"] = clarifyOptions }
        if !senderName.isEmpty { d["senderName"] = senderName }
        if expertOnly { d["expertOnly"] = true }
        if let attachmentType { d["attachmentType"] = attachmentType }
        if let attachmentName { d["attachmentName"] = attachmentName }
        if let attachmentData { d["attachmentData"] = attachmentData }
        return d
    }
}

// MARK: - 案件(BAへのエスカレーション)

enum CaseStatus: String {
    case pending, drafted, answered
}

/// 選択肢に対応するマニュアルの該当箇所
struct ManualRef: Equatable {
    var option: Int
    var manual: String
    var excerpt: String

    init?(dict: [String: Any]) {
        guard let option = (dict["option"] as? NSNumber)?.intValue ?? dict["option"] as? Int,
              let manual = dict["manual"] as? String,
              let excerpt = dict["excerpt"] as? String else { return nil }
        self.option = option; self.manual = manual; self.excerpt = excerpt
    }

    init(option: Int, manual: String, excerpt: String) {
        self.option = option; self.manual = manual; self.excerpt = excerpt
    }

    var dict: [String: Any] { ["option": option, "manual": manual, "excerpt": excerpt] }
}

struct CaseItem: Identifiable, Equatable {
    var id: String
    var roomId: String
    var question: String
    var reason: String
    var options: [String]
    var selectedOption: Int?
    var draft: String?
    var status: CaseStatus
    var askedAt: String
    var answer: String?
    var answeredAt: String?
    /// 対応者(表示名)。空/未設定 = 未対応
    var handledBy: String
    /// nil = 未確認 / [] = 確認済み・該当なし / 非空 = 該当箇所あり
    var manualRefs: [ManualRef]?

    init(id: String = newUid(), roomId: String, question: String, reason: String,
         options: [String], selectedOption: Int? = nil, draft: String? = nil,
         status: CaseStatus = .pending, askedAt: String = nowIso(),
         answer: String? = nil, answeredAt: String? = nil,
         handledBy: String = "", manualRefs: [ManualRef]? = nil) {
        self.id = id; self.roomId = roomId; self.question = question; self.reason = reason
        self.options = options; self.selectedOption = selectedOption; self.draft = draft
        self.status = status; self.askedAt = askedAt; self.answer = answer; self.answeredAt = answeredAt
        self.handledBy = handledBy; self.manualRefs = manualRefs
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        roomId = dict["roomId"] as? String ?? ""
        question = dict["question"] as? String ?? ""
        reason = dict["reason"] as? String ?? ""
        options = dict["options"] as? [String] ?? []
        selectedOption = (dict["selectedOption"] as? NSNumber)?.intValue
        draft = dict["draft"] as? String
        status = CaseStatus(rawValue: dict["status"] as? String ?? "pending") ?? .pending
        askedAt = dict["askedAt"] as? String ?? ""
        answer = dict["answer"] as? String
        answeredAt = dict["answeredAt"] as? String
        handledBy = dict["handledBy"] as? String ?? ""
        if let refs = dict["manualRefs"] as? [[String: Any]] {
            manualRefs = refs.compactMap { ManualRef(dict: $0) }
        } else {
            manualRefs = nil
        }
    }

    var dict: [String: Any] {
        var d: [String: Any] = [
            "id": id, "roomId": roomId, "question": question, "reason": reason,
            "options": options, "status": status.rawValue, "askedAt": askedAt,
        ]
        d["selectedOption"] = selectedOption ?? NSNull()
        d["draft"] = draft ?? NSNull()
        if !handledBy.isEmpty { d["handledBy"] = handledBy }
        if let answer { d["answer"] = answer }
        if let answeredAt { d["answeredAt"] = answeredAt }
        if let manualRefs { d["manualRefs"] = manualRefs.map { $0.dict } }
        return d
    }
}

// MARK: - Q&A ログ

struct QaEntry: Identifiable, Equatable {
    var id: String = newUid()
    var question: String
    var answeredBy: String
    var handler: String?
    var selectedOption: String?
    var answer: String
    var askedAt: String
    var answeredAt: String

    init(question: String, answeredBy: String, handler: String? = nil, selectedOption: String? = nil,
         answer: String, askedAt: String, answeredAt: String) {
        self.question = question; self.answeredBy = answeredBy; self.handler = handler
        self.selectedOption = selectedOption
        self.answer = answer; self.askedAt = askedAt; self.answeredAt = answeredAt
    }

    init(dict: [String: Any]) {
        question = dict["question"] as? String ?? ""
        answeredBy = dict["answered_by"] as? String ?? ""
        handler = dict["handler"] as? String
        selectedOption = dict["selected_option"] as? String
        answer = dict["answer"] as? String ?? ""
        askedAt = dict["asked_at"] as? String ?? ""
        answeredAt = dict["answered_at"] as? String ?? ""
    }

    var dict: [String: Any] {
        var d: [String: Any] = [
            "question": question, "answered_by": answeredBy, "answer": answer,
            "asked_at": askedAt, "answered_at": answeredAt,
        ]
        if let handler { d["handler"] = handler }
        if let selectedOption { d["selected_option"] = selectedOption }
        return d
    }
}

// MARK: - 社内マニュアル

struct Manual: Identifiable, Equatable {
    var id: String
    var title: String
    var content: String
    var updatedAt: String
    /// 元PDF(base64)。プレビュー表示用(約600KB以下のときだけ保持)
    var pdfData: String?

    init(id: String = newUid(), title: String, content: String, updatedAt: String = nowIso(), pdfData: String? = nil) {
        self.id = id; self.title = title; self.content = content; self.updatedAt = updatedAt; self.pdfData = pdfData
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        title = dict["title"] as? String ?? "無題"
        content = dict["content"] as? String ?? ""
        updatedAt = dict["updatedAt"] as? String ?? ""
        pdfData = dict["pdfData"] as? String
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "content": content, "updatedAt": updatedAt]
        if let pdfData { d["pdfData"] = pdfData }
        return d
    }
}

// MARK: - BAトーク(財務同士のトークルーム)

struct BaTalk: Identifiable, Equatable {
    var id: String
    /// グループ名(1:1やBA全体では空)
    var name: String
    var memberUids: [String]   // 空 = 全員(BA全体)
    var memberNames: [String]
    var isGroup: Bool
    var lastText: String
    var lastTs: String
    var createdAt: String
    /// 既読管理: uid → そのユーザーが読んだ最後のメッセージの ts
    var reads: [String: String]
    /// 上部に固定しているユーザーのuid一覧(参加者ごとに固定できる)
    var pinnedBy: [String]
    /// 後から追加されたメンバーの履歴開始点: uid → この時刻以降のメッセージだけ見える
    /// (未設定のメンバーは全履歴が見える)
    var historyFrom: [String: String]

    init(id: String, name: String = "", memberUids: [String] = [], memberNames: [String] = [],
         isGroup: Bool = false, lastText: String = "", lastTs: String = nowIso(), createdAt: String = nowIso(),
         reads: [String: String] = [:], pinnedBy: [String] = [], historyFrom: [String: String] = [:]) {
        self.id = id; self.name = name
        self.memberUids = memberUids; self.memberNames = memberNames
        self.isGroup = isGroup
        self.lastText = lastText; self.lastTs = lastTs; self.createdAt = createdAt
        self.reads = reads
        self.pinnedBy = pinnedBy
        self.historyFrom = historyFrom
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        name = dict["name"] as? String ?? ""
        memberUids = dict["memberUids"] as? [String] ?? []
        memberNames = dict["memberNames"] as? [String] ?? []
        isGroup = dict["isGroup"] as? Bool ?? false
        lastText = dict["lastText"] as? String ?? ""
        lastTs = dict["lastTs"] as? String ?? ""
        createdAt = dict["createdAt"] as? String ?? ""
        reads = dict["reads"] as? [String: String] ?? [:]
        pinnedBy = dict["pinnedBy"] as? [String] ?? []
        historyFrom = dict["historyFrom"] as? [String: String] ?? [:]
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "memberUids": memberUids, "memberNames": memberNames,
                                "isGroup": isGroup, "lastText": lastText, "lastTs": lastTs, "createdAt": createdAt]
        if !reads.isEmpty { d["reads"] = reads }
        if !pinnedBy.isEmpty { d["pinnedBy"] = pinnedBy }
        if !historyFrom.isEmpty { d["historyFrom"] = historyFrom }
        return d
    }
}

// MARK: - BAチャット(財務同士のチャット)

struct BaMessage: Identifiable, Equatable {
    var id: String
    var text: String
    var ts: String
    var senderUid: String
    var senderName: String
    /// 相談チャットへのリンク(貼られている場合)
    var roomId: String?
    var roomTitle: String?
    /// 添付("image" | "file")。データはbase64で埋め込む(600KBまで)
    var attachmentType: String?
    var attachmentName: String?
    var attachmentData: String?
    /// リアクション: 絵文字 → 付けたユーザーのuid一覧
    var reactions: [String: [String]]
    /// 削除済みフラグ(本文は deletedText に退避され「削除されました」表示になる。復元可能)
    var deleted: Bool
    var deletedText: String?

    init(id: String = newUid(), text: String, ts: String = nowIso(),
         senderUid: String, senderName: String, roomId: String? = nil, roomTitle: String? = nil,
         attachmentType: String? = nil, attachmentName: String? = nil, attachmentData: String? = nil) {
        self.id = id; self.text = text; self.ts = ts
        self.senderUid = senderUid; self.senderName = senderName
        self.roomId = roomId; self.roomTitle = roomTitle
        self.attachmentType = attachmentType
        self.attachmentName = attachmentName
        self.attachmentData = attachmentData
        self.reactions = [:]
        self.deleted = false
        self.deletedText = nil
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        text = dict["text"] as? String ?? ""
        ts = dict["ts"] as? String ?? ""
        senderUid = dict["senderUid"] as? String ?? ""
        senderName = dict["senderName"] as? String ?? ""
        roomId = dict["roomId"] as? String
        roomTitle = dict["roomTitle"] as? String
        attachmentType = dict["attachmentType"] as? String
        attachmentName = dict["attachmentName"] as? String
        attachmentData = dict["attachmentData"] as? String
        reactions = dict["reactions"] as? [String: [String]] ?? [:]
        deleted = dict["deleted"] as? Bool ?? false
        deletedText = dict["deletedText"] as? String
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "text": text, "ts": ts,
                                "senderUid": senderUid, "senderName": senderName]
        if let roomId { d["roomId"] = roomId }
        if let roomTitle { d["roomTitle"] = roomTitle }
        if let attachmentType { d["attachmentType"] = attachmentType }
        if let attachmentName { d["attachmentName"] = attachmentName }
        if let attachmentData { d["attachmentData"] = attachmentData }
        return d
    }
}

// MARK: - 役割

enum MemberRole: String {
    case questioner, expert

    var label: String { self == .expert ? "財務" : "担当者" }
}

// MARK: - 所属会社・所属部署・所属担当(一般的な企業グループを想定した選択肢)

enum Companies {
    static let all = [
        "ウエスト",
        "ウエストアカウンティング",
        "ウエスト販売",
        "ウエスト製造",
        "ウエスト物流",
        "ウエストシステムズ",
    ]
}

enum Positions {
    static let all = [
        "部長",
        "課長",
        "係長",
        "主任",
        "一般",
    ]
}

enum Departments {
    static let all = [
        "営業部",
        "経理部",
        "人事部",
        "総務部",
        "経営企画部",
        "情報システム部",
        "マーケティング部",
        "製造部",
        "購買部",
        "法務部",
    ]

    /// 会社ごとの部署の選択肢(会社と部署は紐づいている)
    static let byCompany: [String: [String]] = [
        "ウエスト": all,
        "ウエストアカウンティング": ["経理部", "経営企画部", "総務部"],
        "ウエスト販売": ["営業部", "マーケティング部", "総務部"],
        "ウエスト製造": ["製造部", "購買部", "総務部"],
        "ウエスト物流": ["営業部", "購買部", "総務部"],
        "ウエストシステムズ": ["情報システム部", "営業部", "総務部"],
    ]

    /// 部署ごとの所属担当の選択肢
    static let sections: [String: [String]] = [
        "営業部": ["国内営業担当", "海外営業担当", "営業推進担当"],
        "経理部": ["財務担当", "経費精算担当", "債権管理担当", "税務担当", "給与計算担当"],
        "人事部": ["採用担当", "労務担当", "教育研修担当"],
        "総務部": ["庶務担当", "施設管理担当", "文書管理担当"],
        "経営企画部": ["事業企画担当", "予算管理担当", "IR担当"],
        "情報システム部": ["インフラ担当", "業務システム担当", "ヘルプデスク担当"],
        "マーケティング部": ["宣伝担当", "市場調査担当", "デジタル担当"],
        "製造部": ["生産管理担当", "品質管理担当", "製造技術担当"],
        "購買部": ["資材調達担当", "外注管理担当"],
        "法務部": ["契約担当", "コンプライアンス担当"],
    ]

    static func sections(for department: String) -> [String] {
        sections[department] ?? []
    }

    /// 「会社|部署」をキーにした既定の担当マップ(担当は会社と部署の両方に紐づく)
    static func defaultOrgSections() -> [String: [String]] {
        var m: [String: [String]] = [:]
        for (company, depts) in byCompany {
            for d in depts {
                m["\(company)|\(d)"] = sections[d] ?? []
            }
        }
        return m
    }
}
