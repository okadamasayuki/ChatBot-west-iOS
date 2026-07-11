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

    init(id: String = newUid(), title: String = "新しい相談", createdAt: String = nowIso(),
         lastText: String = "", lastTs: String = nowIso(),
         ownerUid: String = "", ownerEmail: String = "", ownerName: String = "", status: String = "",
         reads: [String: String] = [:], handler: String = "") {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.lastText = lastText; self.lastTs = lastTs
        self.ownerUid = ownerUid; self.ownerEmail = ownerEmail; self.ownerName = ownerName
        self.status = status
        self.reads = reads
        self.handler = handler
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

    init(id: String = newUid(), role: MessageRole, text: String, ts: String = nowIso(),
         clarifyOptions: [String] = [], senderName: String = "") {
        self.id = id; self.role = role; self.text = text; self.ts = ts; self.clarifyOptions = clarifyOptions
        self.deleted = false; self.deletedText = nil
        self.senderName = senderName
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
    }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "role": role.rawValue, "text": text, "ts": ts]
        if !clarifyOptions.isEmpty { d["clarifyOptions"] = clarifyOptions }
        if !senderName.isEmpty { d["senderName"] = senderName }
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

// MARK: - 役割

enum MemberRole: String {
    case questioner, expert

    var label: String { self == .expert ? "財務" : "担当者" }
}
