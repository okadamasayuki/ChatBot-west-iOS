import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// 社内ルールタブ(財務のみ・閲覧+コンパクト整理)
struct NaikiView: View {
    @EnvironmentObject var store: CloudStore
    @State private var showCompact = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(store.naiki)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                        .padding(12)
                }

                Button("🧹 コンパクト") {
                    showCompact = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
                .disabled(store.naiki.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .background(Theme.panelBg)
            .navigationTitle("社内ルール")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCompact) {
                // 重複の統合・言い回しの整理を行った案を確認して置き換える
                NaikiUpdateSheet(
                    title: "社内ルールをコンパクトに",
                    extract: { try await store.compactNaiki() },
                    apply: { text in store.saveNaiki(text) },
                    savedMessage: "✓ 社内ルールを更新しました。全員の回答に反映されます。",
                    applyLabel: "社内ルールを更新",
                    confirmBeforeApply: "現在の社内ルールをこの内容で置き換えます。よろしいですか?",
                    diffBase: store.naiki, // コンパクト前後の差分を表示
                    dismissOnApply: true   // 更新したらシートを閉じる
                )
            }
        }
    }
}

/// 社内マニュアルタブ(財務のみ)
struct ManualView: View {
    @EnvironmentObject var store: CloudStore
    @State private var showImporter = false
    @State private var addStatus: (message: String, ok: Bool)?
    @State private var deleteTarget: Manual?
    @State private var previewTarget: Manual?
    @State private var showExtractAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("📄 ファイルを選択して追加") { showImporter = true }
                    if let addStatus {
                        Text(addStatus.message)
                            .font(.footnote)
                            .foregroundColor(addStatus.ok ? Theme.accentDark : .red)
                    }
                }

                Section("登録済みマニュアル") {
                    if store.manuals.isEmpty {
                        Text("まだマニュアルはありません。上のフォームから追加してください。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.manuals.sorted { $0.updatedAt > $1.updatedAt }) { m in
                        Button {
                            previewTarget = m
                        } label: {
                            Text(m.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(red: 0x0a / 255, green: 0x6e / 255, blue: 0xbd / 255))
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteTarget = m
                            } label: {
                                Text("削除")
                            }
                        }
                    }
                }

                Section {
                    Button("📋 マニュアルから社内ルールを抽出") {
                        showExtractAll = true
                    }
                    .disabled(store.manuals.isEmpty)
                } footer: {
                    Text("マニュアルから、既存の社内ルールにない項目(差分)をAIが抽出します。社内固有のルールだけが対象です。")
                }
            }
            .navigationTitle("マニュアル")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText],
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                importFile(url)
            }
            .confirmationDialog("このマニュアルを削除しますか?",
                                isPresented: Binding(get: { deleteTarget != nil },
                                                     set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let m = deleteTarget { store.deleteManual(m.id) }
                    deleteTarget = nil
                }
                Button("キャンセル", role: .cancel) { deleteTarget = nil }
            }
            .sheet(item: $previewTarget) { m in
                ManualPreviewSheet(manual: m)
            }
            .sheet(isPresented: $showExtractAll) {
                NaikiUpdateSheet(
                    title: "マニュアルから社内ルールを抽出",
                    extract: {
                        let src = store.manuals
                            .map { "# \($0.title.isEmpty ? "無題" : $0.title)\n\($0.content)" }
                            .joined(separator: "\n\n")
                        return try await store.extractNaikiFromManuals(src)
                    },
                    apply: { text in store.appendToNaiki(text, separator: "\n\n") },
                    savedMessage: "✓ 社内ルールの末尾に追加しました。全員の回答に反映されます。"
                )
            }
        }
    }

    /// ファイルを選ぶとその場でマニュアルを追加(タイトル=ファイル名、本文=中身)。Web版と同じ挙動。
    private func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let title = url.deletingPathExtension().lastPathComponent
        let isPdf = url.pathExtension.lowercased() == "pdf"
        do {
            if isPdf {
                let data = try Data(contentsOf: url)
                guard let text = PdfUtils.extractText(data), !text.isEmpty else {
                    addStatus = ("PDFから文字を抽出できませんでした(画像だけのスキャンPDFの可能性)。", false)
                    return
                }
                // 元PDF(base64)はプレビュー用。Firestoreの1MB制限に収まる場合のみ保持
                let pdfData = data.count <= PdfUtils.keepLimit ? data.base64EncodedString() : nil
                store.addManual(title: title, content: text, pdfData: pdfData)
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                store.addManual(title: title, content: text)
            }
            addStatus = ("「\(title)」を追加しました。", true)
        } catch {
            addStatus = ("読み込みに失敗しました: \(error.localizedDescription)", false)
        }
    }
}

/// マニュアルのプレビュー(元PDFがあればPDFをそのまま描画、なければ抽出テキスト)。
/// `highlight` を渡すと該当箇所を黄色でハイライトする(PDFは自動スクロールも行う)
struct ManualPreviewSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let manual: Manual
    var highlight: String? = nil
    @State private var showExtract = false
    // PDFDocumentはbodyの再評価ごとに作り直さない(差し替えでハイライトがリセットされるレースを防ぐ)
    @State private var pdfDoc: PDFDocument?
    @State private var pdfLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                if let doc = pdfDoc {
                    PdfKitView(document: doc, highlight: highlight)
                } else {
                    ScrollView {
                        Text(highlightedContent)
                            .font(.system(size: 13))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .navigationTitle(manual.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !pdfLoaded else { return }
                pdfLoaded = true
                if let b64 = manual.pdfData, let data = Data(base64Encoded: b64) {
                    pdfDoc = PDFDocument(data: data)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("📋 社内ルールを抽出") { showExtract = true }
                        .font(.system(size: 13))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showExtract) {
                NaikiUpdateSheet(
                    title: "マニュアルから社内ルールを抽出",
                    extract: {
                        try await store.extractNaikiFromManuals("# \(manual.title)\n\(manual.content)")
                    },
                    apply: { text in store.appendToNaiki(text, separator: "\n\n") },
                    savedMessage: "✓ 社内ルールの末尾に追加しました。全員の回答に反映されます。"
                )
            }
        }
    }

    /// テキストプレビュー用: 該当箇所に黄色の背景を付ける。
    /// 完全一致しない場合は空白除去 → 先頭24/16/10/6文字と段階的に短くして再検索
    private var highlightedContent: AttributedString {
        var attr = AttributedString(manual.content.isEmpty ? "(内容なし)" : manual.content)
        guard let h = highlight?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return attr }
        let clean = h
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」『』()()。、・…※"))
        var candidates: [String] = [h]
        if clean != h { candidates.append(clean) }
        for len in [24, 16, 10, 6] where clean.count > len {
            candidates.append(String(clean.prefix(len)))
        }
        for probe in candidates where probe.count >= 4 {
            if let range = attr.range(of: probe) {
                attr[range].backgroundColor = Color.yellow.opacity(0.55)
                return attr
            }
        }
        return attr
    }
}

// MARK: - PDF ユーティリティ

enum PdfUtils {
    /// 元PDFを保持する上限(約600KB。Web版 PDF_KEEP_LIMIT と同じ)
    static let keepLimit = 600 * 1024

    static func extractText(_ data: Data) -> String? {
        guard let doc = PDFDocument(data: data) else { return nil }
        var text = ""
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.string { text += s + "\n" }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PdfKitView: UIViewRepresentable {
    let document: PDFDocument
    var highlight: String? = nil

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayDirection = .vertical
        scheduleHighlight(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            scheduleHighlight(view)
        }
    }

    /// PDFViewの描画準備が終わる前に設定すると反映されないことがあるため、
    /// 時間差で複数回適用する(適用は冪等。スクロールは初回のみ)
    private func scheduleHighlight(_ view: PDFView) {
        for delay in [0.0, 0.3, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                applyHighlight(view)
            }
        }
    }

    /// 該当箇所を黄色でハイライトし、最初のマッチへスクロールする(再適用は冪等・スクロールは初回のみ)
    private func applyHighlight(_ view: PDFView) {
        guard let h = highlight?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return }
        let selections = findSelections(h)
        guard !selections.isEmpty else { return }
        let firstTime = (view.highlightedSelections ?? []).isEmpty
        for sel in selections {
            sel.color = UIColor.systemYellow.withAlphaComponent(0.6)
        }
        // 注釈ではなく PDFView 標準のハイライト表示を使う(注釈は環境によって描画されないため)
        view.highlightedSelections = selections
        if firstTime, let first = selections.first {
            DispatchQueue.main.async { view.go(to: first) }
        }
    }

    /// 引用に対応する範囲をPDFから探す。
    /// PDF内部のテキストは改行・空白の入り方が引用と異なるため、
    /// 空白を除去した正規化テキスト同士で照合し、見つかった範囲を元のテキスト位置に
    /// 逆マッピングして選択範囲を作る(引用の全体がハイライトされる)。
    private func findSelections(_ text: String) -> [PDFSelection] {
        let normExcerptChars = Array(Self.normalizedWithMap(text).0)
        let n = normExcerptChars.count
        guard n >= 6 else { return [] }
        let anchorLen = min(10, n)

        // 引用の冒頭がAIの言い換えで原文と違う場合に備え、
        // アンカー(照合の足がかり)は引用の先頭・1/4・中央・3/4 の複数位置から取る
        var anchors: [String] = []
        for offset in [0, n / 4, n / 2, (3 * n) / 4] {
            guard offset + anchorLen <= n else { continue }
            let probe = String(normExcerptChars[offset..<(offset + anchorLen)])
            if !anchors.contains(probe) { anchors.append(probe) }
        }

        // ページごとにアンカーを探し、一致箇所を含む文の区切り(「。」や改行)まで
        // 広げてハイライトする(項目全体が引かれる)
        for anchor in anchors {
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i), let pageText = page.string else { continue }
                let (norm, map) = Self.normalizedWithMap(pageText)
                guard let r = norm.range(of: anchor) else { continue }
                let startNorm = norm.distance(from: norm.startIndex, to: r.lowerBound)
                let endNorm = norm.distance(from: norm.startIndex, to: r.upperBound) - 1
                guard startNorm < map.count, endNorm < map.count else { continue }

                let chars = Array(pageText)
                var s = map[startNorm]
                var e = map[endNorm]
                // 項目の区切りまで拡張(引用が短い/部分一致でも中途半端にならない)。
                // 区切り = 「。」または「数字.」で始まる行頭(=箇条書き項目の先頭)。
                // 行の折り返しの改行はまたいで広げる。広がりすぎ防止で前後120文字まで
                var budget = 120
                while s > 0, budget > 0 {
                    let prev = chars[s - 1]
                    if prev == "。" { break }
                    if prev == "\n", Self.isItemStart(chars, at: s) { break } // 自分の項目の先頭
                    s -= 1; budget -= 1
                }
                budget = 120
                while e < chars.count - 1, chars[e] != "。", budget > 0 {
                    if chars[e] == "\n", Self.isItemStart(chars, at: e + 1) { e -= 1; break } // 次の項目の直前
                    e += 1; budget -= 1
                }
                // 範囲の先頭・末尾の空白/改行を除く(改行が前の行末に描画され、
                // 前の文の「。」までマーカーが付いて見えるのを防ぐ)
                while s < e, chars[s].isWhitespace || chars[s].isNewline { s += 1 }
                while e > s, chars[e].isWhitespace || chars[e].isNewline { e -= 1 }
                let sIdx = pageText.index(pageText.startIndex, offsetBy: s)
                let eIdx = pageText.index(pageText.startIndex, offsetBy: e + 1)
                if let sel = page.selection(for: NSRange(sIdx..<eIdx, in: pageText)) {
                    return [sel]
                }
            }
        }
        return []
    }

    /// 指定位置から「数字.」(箇条書き項目の先頭)が始まるか
    static func isItemStart(_ chars: [Character], at index: Int) -> Bool {
        var j = index
        while j < chars.count, chars[j] == " " || chars[j] == "　" { j += 1 }
        var hasDigit = false
        while j < chars.count, chars[j].isNumber { hasDigit = true; j += 1 }
        return hasDigit && j < chars.count && (chars[j] == "." || chars[j] == "．" || chars[j] == "、" || chars[j] == ")" || chars[j] == ")")
    }

    /// 照合用の正規化: 空白・改行・句読点・記号を除去し、全角半角と大文字小文字の差も吸収する。
    /// 「正規化後の位置 → 元のテキスト位置」の対応表も返す(ハイライト範囲の逆マッピング用)
    static func normalizedWithMap(_ s: String) -> (String, [Int]) {
        let skip = CharacterSet(charactersIn: "、。・,.;:()()[]「」『』【】〈〉《》\"'‘’“”‐-–—〜~…※　 !?！?")
        var norm = ""
        var map: [Int] = []
        for (idx, ch) in s.enumerated() {
            if ch.isWhitespace || ch.isNewline { continue }
            let str = String(ch)
            if str.rangeOfCharacter(from: skip) != nil { continue }
            let converted = (str.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? str).lowercased()
            for c in converted {
                norm.append(c)
                map.append(idx)
            }
        }
        return (norm, map)
    }
}
