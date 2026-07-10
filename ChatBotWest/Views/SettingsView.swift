import SwiftUI
import UIKit

/// 設定タブ: アカウント / サンプルデータ / 財務向け管理 / 回答の癖 / Q&A履歴ダウンロード
struct SettingsView: View {
    @EnvironmentObject var store: CloudStore
    @State private var shareURL: URL?
    @State private var sampleBusy = false
    @State private var sampleNote: String?
    @State private var manualBusy: String?
    @State private var manualNote: String?
    @State private var styleText = ""
    @State private var styleSavedNote = false
    @FocusState private var styleFocused: Bool
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteAllFinal = false
    @State private var confirmClearNaiki = false
    @State private var deleteAllBusy = false
    @State private var errorNote: String?

    private static let sampleManuals: [(slug: String, title: String)] = [
        ("keihi", "経費精算マニュアル"),
        ("kotei", "固定資産管理マニュアル"),
        ("kosai", "交際費・会議費マニュアル"),
        ("invoice", "インボイス・消費税マニュアル"),
        ("kyuyo", "給与・社会保険マニュアル"),
        ("uriage", "売上計上マニュアル"),
        ("saiken", "債権管理マニュアル"),
        ("gaika", "外貨建取引マニュアル"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("☁ アカウント") {
                    if store.user != nil {
                        LabeledContent("ログイン中", value: store.myName())
                        LabeledContent("役割", value: store.role?.label ?? "-")
                    }
                    Button("ログアウト", role: .destructive) {
                        store.logout()
                    }
                }

                Section {
                    Button {
                        addSamples()
                    } label: {
                        HStack {
                            if sampleBusy { ProgressView().padding(.trailing, 6) }
                            Text("サンプル相談を追加(デモ)")
                        }
                    }
                    .disabled(sampleBusy)
                    if let sampleNote {
                        Text(sampleNote).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("📄 サンプルマニュアル") {
                    ForEach(Self.sampleManuals, id: \.slug) { item in
                        Button {
                            addSampleManual(item.slug, item.title)
                        } label: {
                            HStack {
                                if manualBusy == item.slug { ProgressView().padding(.trailing, 6) }
                                Text("📄 \(item.title) を追加")
                            }
                        }
                        .disabled(manualBusy != nil)
                    }
                    if let manualNote {
                        Text(manualNote).font(.footnote).foregroundColor(.secondary)
                    }
                }

                if store.isExpert {
                    Section("💬 相談データ") {
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            HStack {
                                if deleteAllBusy { ProgressView().padding(.trailing, 6) }
                                Text("🗑 相談をすべて削除")
                            }
                        }
                        .disabled(deleteAllBusy)
                    }

                    Section("📘 社内ルール") {
                        Button("🗑 社内ルールを空にする", role: .destructive) {
                            confirmClearNaiki = true
                        }
                    }

                    Section {
                        TextEditor(text: $styleText)
                            .font(.system(size: 13))
                            .focused($styleFocused)
                            .frame(minHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if styleText.isEmpty {
                                    Text("- 結論を先に書く\n- です・ます調で丁寧に\n- 最後に「ご不明点があればご連絡ください。」を添える")
                                        .font(.system(size: 13))
                                        .foregroundColor(Color(.placeholderText))
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                        Button("回答の癖を保存") {
                            styleFocused = false // 保存したらキーボードを閉じる
                            store.saveAnswerStyle(styleText)
                            styleSavedNote = true
                        }
                        if styleSavedNote {
                            Text("✓ 保存しました。あなたがAIに回答文を作らせるときに参照されます。")
                                .font(.footnote)
                                .foregroundColor(Theme.accentDark)
                        }
                    } header: {
                        Text("✍️ 回答の癖(回答スタイル)")
                    } footer: {
                        Text("回答の書き方の癖を登録すると、あなたがAIに回答文を作らせるときに参照されます(このアカウント専用)。")
                    }
                }

                Section("⬇ Q&A履歴のダウンロード") {
                    LabeledContent("保存されているQ&A", value: "\(store.qaLog.count)件")
                    Button("JSON をエクスポート") { export(asCsv: false) }
                    Button("CSV をエクスポート(Excel対応)") { export(asCsv: true) }
                }

                if let errorNote {
                    Section {
                        Text("⚠ \(errorNote)").font(.footnote).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            // 下にスクロールするとキーボードが閉じる + キーボード上部に「完了」ボタン
            .scrollDismissesKeyboard(.interactively)
            // 入力欄の外をタップするとキーボードを閉じる
            .onTapGesture { styleFocused = false }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { styleFocused = false }
                }
            }
            .onAppear { styleText = store.answerStyle }
            .onChange(of: store.answerStyle) { s in
                // Web版などでの変更をリアルタイム反映(このアプリで編集中のときは上書きしない)
                if !styleFocused { styleText = s }
            }
            .sheet(item: $shareURL) { url in
                ActivityView(items: [url])
            }
            .confirmationDialog("すべての相談・BAの案件・回答履歴を削除しますか?\n全員の画面から消え、元に戻せません。",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("削除する", role: .destructive) { confirmDeleteAllFinal = true }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog("本当に削除しますか?(最終確認)",
                                isPresented: $confirmDeleteAllFinal, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { deleteAllRooms() }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog("社内ルールをすべて削除して空にしますか?\n(全員の回答に反映されます。元に戻せません)",
                                isPresented: $confirmClearNaiki, titleVisibility: .visible) {
                Button("空にする", role: .destructive) { store.saveNaiki("") }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    private func export(asCsv: Bool) {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            return f.string(from: Date())
        }()
        let name = "qa-history-\(stamp).\(asCsv ? "csv" : "json")"
        let content = asCsv ? QaExport.csv(store.qaLog) : QaExport.json(store.qaLog)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
        } catch {
            errorNote = "エクスポートに失敗しました: \(error.localizedDescription)"
        }
    }

    private func addSamples() {
        sampleBusy = true
        sampleNote = nil
        Task {
            do {
                let n = try await SampleData.addToCloud(store: store)
                sampleNote = n > 0 ? "サンプル相談を\(n)件追加しました。"
                    : "サンプルは既に追加済みのため、メッセージ・案件の状態を初期状態に修復しました。"
            } catch {
                sampleNote = "追加に失敗しました: \(error.localizedDescription)"
            }
            sampleBusy = false
        }
    }

    private func addSampleManual(_ slug: String, _ title: String) {
        manualBusy = slug
        manualNote = nil
        Task {
            do {
                try await SampleData.addSampleManual(slug: slug, title: title, store: store)
                manualNote = "✓「\(title)」を追加しました。"
            } catch {
                manualNote = "追加に失敗しました: \(error.localizedDescription)"
            }
            manualBusy = nil
        }
    }

    private func deleteAllRooms() {
        deleteAllBusy = true
        Task {
            do {
                try await store.deleteAllRooms()
                sampleNote = "すべての相談を削除しました。"
            } catch {
                errorNote = "削除に失敗しました: \(error.localizedDescription)"
            }
            deleteAllBusy = false
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

/// UIActivityViewController(共有シート)のラッパー
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Q&A履歴の JSON / CSV 生成(Web版と同一フォーマット)
enum QaExport {
    static func json(_ log: [QaEntry]) -> String {
        let arr = log.map { $0.dict }
        let data = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func csv(_ log: [QaEntry]) -> String {
        func esc(_ v: String?) -> String {
            "\"" + (v ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = [["質問日時", "質問", "回答者", "対応者", "選択された方針", "回答", "回答日時"].map { esc($0) }.joined(separator: ",")]
        for q in log {
            rows.append([q.askedAt, q.question, q.answeredBy, q.handler ?? "", q.selectedOption ?? "", q.answer, q.answeredAt]
                .map { esc($0) }.joined(separator: ","))
        }
        // Excel で文字化けしないよう BOM 付き UTF-8
        return "\u{FEFF}" + rows.joined(separator: "\r\n")
    }
}
