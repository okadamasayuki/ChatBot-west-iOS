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
                    diffBase: store.naiki // コンパクト前後の差分を表示
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

/// マニュアルのプレビュー(元PDFがあればPDFをそのまま描画、なければ抽出テキスト)
struct ManualPreviewSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let manual: Manual
    @State private var showExtract = false

    var body: some View {
        NavigationStack {
            Group {
                if let b64 = manual.pdfData, let data = Data(base64Encoded: b64),
                   let doc = PDFDocument(data: data) {
                    PdfKitView(document: doc)
                } else {
                    ScrollView {
                        Text(manual.content.isEmpty ? "(内容なし)" : manual.content)
                            .font(.system(size: 13))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .navigationTitle(manual.title)
            .navigationBarTitleDisplayMode(.inline)
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

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
