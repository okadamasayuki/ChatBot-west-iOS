import Foundation
import CryptoKit
import FirebaseFirestore

/// デモ用サンプルデータ(Web版 exampleData / addSampleConsultations / addSampleManual と同一)
enum SampleData {

    struct Example {
        var room: Room
        var msgs: [Message]
        var caseObj: CaseItem?
    }

    private static let escText = "ご質問ありがとうございます。この内容はBAによる確認が必要なため、BAにおつなぎしました。回答までしばらくお待ちください。"

    /// 常に「過去48時間前」を起点に1時間刻み(未来の時刻を作らない。実際の返信が必ず後ろに並ぶ)
    static func examples() -> [Example] {
        let base = Date().addingTimeInterval(-48 * 3600)
        var hour = 0
        func ts() -> String {
            let d = base.addingTimeInterval(Double(hour) * 3600)
            hour += 1
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            return fmt.string(from: d)
        }

        func ai(_ id: String, _ title: String, _ q: String, _ a: String) -> Example {
            let t = ts(), t2 = ts()
            return Example(
                room: Room(id: id, title: title, createdAt: t, lastText: a, lastTs: t2),
                msgs: [Message(id: id + "u", role: .user, text: q, ts: t),
                       Message(id: id + "a", role: .ai, text: a, ts: t2)],
                caseObj: nil
            )
        }
        func escP(_ id: String, _ title: String, _ q: String, _ reason: String, _ options: [String]) -> Example {
            let t = ts(), t2 = ts()
            return Example(
                room: Room(id: id, title: title, createdAt: t, lastText: escText, lastTs: t2),
                msgs: [Message(id: id + "u", role: .user, text: q, ts: t),
                       Message(id: id + "a", role: .ai, text: escText, ts: t2)],
                caseObj: CaseItem(id: "c" + id, roomId: id, question: q, reason: reason,
                                  options: options, status: .pending, askedAt: t)
            )
        }
        func escA(_ id: String, _ title: String, _ q: String, _ reason: String,
                  _ options: [String], _ sel: Int, _ answer: String) -> Example {
            let t = ts(), t2 = ts(), t3 = ts()
            return Example(
                room: Room(id: id, title: title, createdAt: t, lastText: "【BA】" + answer, lastTs: t3),
                msgs: [Message(id: id + "u", role: .user, text: q, ts: t),
                       Message(id: id + "a", role: .ai, text: escText, ts: t2),
                       Message(id: id + "e", role: .expert, text: answer, ts: t3)],
                caseObj: CaseItem(id: "c" + id, roomId: id, question: q, reason: reason,
                                  options: options, selectedOption: sel,
                                  status: .answered, askedAt: t, answer: answer, answeredAt: t3)
            )
        }

        return [
            ai("ex1", "減価償却はどの方法で計算すればいい?", "減価償却はどの方法で計算すればいいですか?", "当事務所の社内ルールでは、減価償却は定額法で計算します。取得価額を耐用年数にわたって毎期均等に費用計上してください(例: 120万円・6年なら毎年20万円)。"),
            ai("ex2", "3万円のプリンターの勘定科目は?", "3万円のプリンターを買いました。勘定科目は何になりますか?", "取得価額が10万円未満の物品は「消耗品費」として購入時に一括で費用計上できます。資産計上・減価償却は不要です。"),
            ai("ex3", "飲食代は交際費?会議費?", "取引先との飲食代は交際費ですか?会議費ですか?", "1人あたり5,000円以下で日付・参加者・目的の要件を満たす飲食は「会議費」、それを超える接待目的の飲食は「交際費」になります。"),
            ai("ex11", "領収書のない交通費の精算は?", "領収書が出ない電車代はどう精算すればいいですか?", "電車・バスなど領収書が出ない交通費は、日付・区間・金額・目的を記した出金伝票や交通費精算書で精算できます。ICカードの利用履歴を添付すると確実です。"),
            ai("ex12", "前受金はいつ売上に計上する?", "来月分のサービス料を前もって受け取りました。売上はいつ計上しますか?", "代金を先に受け取った時点では「前受金(負債)」で処理し、サービスを提供した月に売上へ振り替えます。実現主義に基づく処理です。"),

            escP("ex5", "500万円の機械を全額経費にできる?", "500万円の機械を導入予定です。全額その年の経費にできますか?",
                 "高額資産の取得で、原則は資産計上・減価償却だが、特別償却や中小企業向け特例の適用可否は個別判断が必要なため。",
                 ["原則どおり資産計上し定額法で減価償却すると案内する", "中小企業経営強化税制など特例で即時償却できる可能性を案内する", "適用要件の確認が必要なため追加情報を依頼する"]),
            escP("ex6", "貸倒引当金は計上できる?", "取引先が倒産しそうです。売掛金に貸倒引当金を計上できますか?",
                 "貸倒引当金・貸倒損失は相手先の状況(法的整理・実質破綻など)で処理と時期が変わり、個別判断が必要なため。",
                 ["個別評価が必要なため状況を確認して案内する", "法的整理の有無で処理が変わると案内する"]),
            escP("ex7", "簡易課税と原則課税どちらが得?", "消費税は簡易課税と原則課税のどちらが有利ですか?",
                 "有利判定は売上・経費構成やみなし仕入率、設備投資予定で変わり、シミュレーションが必要なため。",
                 ["業種のみなし仕入率で試算して案内する", "設備投資予定の有無を確認して案内する", "両方式を試算のうえ提案する"]),
            escP("ex9", "従業員への慶弔見舞金は損金?", "従業員に結婚祝い金を渡しました。損金になりますか?",
                 "慶弔見舞金は社会通念上相当な金額かどうか、慶弔規程の有無で損金性が変わるため。",
                 ["慶弔規程に基づく相当額なら損金と案内する", "規程の整備状況を確認して案内する"]),
            escP("ex10", "海外送金の為替差損益の処理は?", "ドル建ての売掛金を回収しました。為替差損益はどう処理しますか?",
                 "換算レート(取引時・決算時・回収時)の適用や継続適用の要件で処理が変わり、個別確認が必要なため。",
                 ["取引時と回収時のレート差を為替差損益で処理と案内する", "期末の換算方法(継続適用)を確認して案内する"]),
            escP("ex14", "社宅家賃はどこまで給与課税される?", "会社で社宅を借りて社員に貸します。家賃はどこまで給与課税されますか?",
                 "賃貸料相当額の計算(固定資産税評価額ベース)や本人負担割合で課税範囲が変わるため。",
                 ["賃貸料相当額の50%以上を本人負担にすれば非課税と案内する", "評価額の確認が必要なため資料を依頼する"]),

            escA("ex4", "役員報酬を期中に増額できる?", "役員報酬を今期の途中から増額したいのですが、損金算入できますか?",
                 "役員報酬の期中改定は損金算入の可否が個別事情で変わり、税務上の専門判断が必要なため。",
                 ["原則は期中増額分が損金不算入になると案内する", "業績悪化改定など例外に該当するか個別確認が必要と案内する"], 1,
                 "役員報酬は原則として期首から3か月以内の改定(定期同額給与)でないと、増額分が損金不算入となる可能性があります。期中増額は業績悪化改定などの例外に該当するか個別確認が必要ですので、事前に担当税理士へご相談ください。"),
            escA("ex8", "固定資産の除却損はいつ計上する?", "古い設備を廃棄しました。除却損はいつ計上できますか?",
                 "除却の事実認定(実際の廃棄・使用停止)や有姿除却の要件で計上時期が変わるため。",
                 ["実際に廃棄した事業年度に計上と案内する", "有姿除却の要件を満たすか確認して案内する"], 0,
                 "固定資産の除却損は、実際に廃棄・処分した事業年度に計上します。廃棄業者の処分証明や写真など、除却の事実を示す資料を保管してください。まだ廃棄していない場合は有姿除却の要件確認が必要です。"),
            escA("ex13", "中古車の耐用年数は?", "4年落ちの中古車を購入しました。耐用年数は何年になりますか?",
                 "中古資産の耐用年数は簡便法・見積法の選択や経過年数で変わり、個別計算が必要なため。",
                 ["簡便法で計算した年数(最短2年)を案内する", "見積法との比較が必要と案内する"], 0,
                 "中古車は簡便法により「(法定耐用年数6年−経過4年)+経過4年×20%＝2.8年→2年」となります(1年未満切捨て・最短2年)。事業供用日基準で計算しますので、取得時期もあわせてご確認ください。"),
            escA("ex15", "決算賞与を損金にする要件は?", "決算月に賞与を支給予定です。今期の損金にするには?",
                 "未払計上での損金算入は支給額の通知・支給時期・経理処理の3要件を満たす必要があり、確認が必要なため。",
                 ["3要件(通知・1か月以内支給・未払計上)を満たせば損金と案内する", "支給通知の方法を確認して案内する"], 0,
                 "決算賞与を未払計上で今期の損金にするには、①各人別に支給額を通知し、②決算日の翌日から1か月以内に全員へ支給し、③通知した期に未払費用として損金経理する、の3要件をすべて満たす必要があります。通知書の保管をお願いします。"),
        ]
    }

    /// サンプル相談をクラウド(Firestore)に追加。既存(同じID)は時刻・状態を修復。追加件数を返す。
    @MainActor
    static func addToCloud(store: CloudStore) async throws -> Int {
        let db = Firestore.firestore()
        let wid = widHex()
        let ws = db.collection("workspaces").document(wid)
        var added = 0

        for e in examples() {
            let roomRef = ws.collection("rooms").document(e.room.id)
            if store.rooms.contains(where: { $0.id == e.room.id }) {
                // 既存サンプル: 正規の状態にリセットする(旧IDの残骸や重複を消し、時刻も揃える)
                let keep = Set(e.msgs.map { $0.id })
                let msnap = try await roomRef.collection("messages").getDocuments()
                for d in msnap.documents where !keep.contains(d.documentID) {
                    try await d.reference.delete()
                }
                for msg in e.msgs {
                    try await roomRef.collection("messages").document(msg.id).setData(msg.dict)
                }
                try await roomRef.setData([
                    "title": e.room.title, "createdAt": e.room.createdAt,
                    "lastTs": e.room.lastTs, "lastText": e.room.lastText, "status": "",
                ], merge: true)
                // 案件も正規の状態にリセット(チャットとBAタブの不整合を残さない)
                for c in store.cases where c.roomId == e.room.id && c.id != e.caseObj?.id {
                    try await ws.collection("cases").document(c.id).delete()
                }
                if let caseObj = e.caseObj {
                    try await ws.collection("cases").document(caseObj.id).setData(caseObj.dict)
                }
                continue
            }
            var room = e.room
            room.ownerUid = store.myUid()
            room.ownerEmail = store.user?.email ?? ""
            try await roomRef.setData(room.dict)
            for msg in e.msgs {
                try await roomRef.collection("messages").document(msg.id).setData(msg.dict)
            }
            if let caseObj = e.caseObj, !store.cases.contains(where: { $0.id == caseObj.id }) {
                try await ws.collection("cases").document(caseObj.id).setData(caseObj.dict)
            }
            added += 1
        }
        return added
    }

    /// サンプルマニュアル(PDF)を取得→文字抽出→追加(固定IDで重複なし)
    @MainActor
    static func addSampleManual(slug: String, title: String, store: CloudStore) async throws {
        let url = URL(string: "https://raw.githubusercontent.com/okadamasayuki/chatbot-west/main/samples/manuals/\(slug).pdf")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "SampleData", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PDFを取得できませんでした"])
        }
        guard let text = PdfUtils.extractText(data) else {
            throw NSError(domain: "SampleData", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PDFから文字を抽出できませんでした"])
        }
        let pdfData = data.count <= PdfUtils.keepLimit ? data.base64EncodedString() : nil
        store.addManual(title: title, content: text, pdfData: pdfData, id: "sample-manual-\(slug)")
    }

    private static func widHex() -> String {
        SHA256.hash(data: Data(FirebaseSetup.workspaceCode.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
