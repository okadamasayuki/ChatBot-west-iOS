import SwiftUI
import UIKit
import PhotosUI

/// アイコン設定: 絵文字から選ぶ / 写真から選ぶ / AIで自動生成
struct IconSettingView: View {
    @EnvironmentObject var store: CloudStore
    @State private var photosItem: PhotosPickerItem?
    @State private var aiPrompt = ""
    @State private var aiBusy = false
    @State private var aiPreview: UIImage?
    @State private var errorMessage: String?

    private static let emojis = ["😀", "😎", "🤓", "🥸", "😺", "🐶", "🐱", "🐰", "🦊", "🐻",
                                 "🐼", "🐨", "🦁", "🐯", "🐸", "🐥", "🦉", "🐢", "🐬", "🦄",
                                 "🌻", "🌸", "🍀", "⭐️", "🔥", "⚡️", "🍎", "☕️", "⚽️", "🎸"]

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    AvatarCircleView(iconData: store.myIconData, icon: store.myIcon, size: 88)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("絵文字から選ぶ") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button {
                            store.saveIcon(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(store.myIcon == emoji && store.myIconData.isEmpty
                                            ? Theme.accent.opacity(0.2) : Color.clear)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("写真から選ぶ") {
                PhotosPicker(selection: $photosItem, matching: .images) {
                    Label("写真を選択", systemImage: "photo")
                }
            }

            Section {
                TextField("例: 海が好きな猫、山とコーヒー", text: $aiPrompt)
                if let aiPreview {
                    HStack {
                        Spacer()
                        Image(uiImage: aiPreview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                        Spacer()
                    }
                }
                HStack {
                    Button {
                        generate()
                    } label: {
                        if aiBusy {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("生成中…") }
                        } else {
                            Label(aiPreview == nil ? "AIで生成" : "作り直す", systemImage: "sparkles")
                        }
                    }
                    .disabled(aiBusy || aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if let aiPreview {
                        Button("これに設定") {
                            if let data = aiPreview.jpegData(compressionQuality: 0.8) {
                                store.saveIconImage(data)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                }
                if let errorMessage {
                    Text("⚠ \(errorMessage)").font(.footnote).foregroundColor(.red)
                }
            } header: {
                Text("AIで自動生成")
            } footer: {
                Text("イメージを入力すると、AIが絵文字と配色を選んでアイコンを生成します。")
            }
        }
        .navigationTitle("アイコンを設定")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photosItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    // 正方形に切り出して縮小(メンバー情報に収まるサイズへ)
                    let side = min(image.size.width, image.size.height)
                    let crop = CGRect(x: (image.size.width - side) / 2,
                                      y: (image.size.height - side) / 2,
                                      width: side, height: side)
                    if let cg = image.cgImage?.cropping(to: crop) {
                        let square = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
                        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
                        let resized = renderer.image { _ in
                            square.draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
                        }
                        if let jpeg = resized.jpegData(compressionQuality: 0.8) {
                            store.saveIconImage(jpeg)
                        }
                    }
                }
                photosItem = nil
            }
        }
    }

    private func generate() {
        aiBusy = true
        errorMessage = nil
        Task {
            do {
                let spec = try await store.generateIconSpec(from: aiPrompt)
                aiPreview = AvatarRenderer.render(emoji: spec.emoji, topHex: spec.top, bottomHex: spec.bottom)
            } catch {
                errorMessage = "生成に失敗しました: \(error.localizedDescription)"
            }
            aiBusy = false
        }
    }
}

/// 設定タブ: アカウント / サンプルデータ / 財務向け管理 / 回答の癖 / Q&A履歴ダウンロード
struct SettingsView: View {
    @EnvironmentObject var store: CloudStore
    @State private var shareURL: URL?
    @State private var sampleBusy = false
    @State private var sampleNote: String?
    @State private var styleText = ""
    @State private var styleSavedNote = false
    @FocusState private var styleFocused: Bool
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteAllFinal = false
    @State private var confirmClearNaiki = false
    @State private var deleteAllBusy = false
    @State private var errorNote: String?
    @State private var manualBusy: String?
    @State private var manualNote: String?

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
                        NavigationLink {
                            IconSettingView()
                        } label: {
                            HStack(spacing: 14) {
                                AvatarCircleView(iconData: store.myIconData, icon: store.myIcon, size: 72)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.myName()).font(.system(size: 18, weight: .semibold))
                                    Text(store.role?.label ?? "-").font(.footnote).foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
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
                        // 確認ダイアログはボタンごとに付ける(同じビューに複数まとめると動かないため)
                        .alert("すべての相談・BAの案件・回答履歴を削除します。\nよろしいですか?",
                               isPresented: $confirmDeleteAll) {
                            Button("キャンセル", role: .cancel) {}
                            Button("削除", role: .destructive) {
                                // 1つ目のアラートが閉じ切ってから最終確認を出す
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    confirmDeleteAllFinal = true
                                }
                            }
                        }
                        .alert("本当に削除しますか?(最終確認)", isPresented: $confirmDeleteAllFinal) {
                            Button("キャンセル", role: .cancel) {}
                            Button("すべて削除", role: .destructive) { deleteAllRooms() }
                        }
                    }

                    Section("📘 社内ルール") {
                        NavigationLink("社内ルールを見る") {
                            NaikiView()
                        }
                        Button("🗑 社内ルールを空にする", role: .destructive) {
                            confirmClearNaiki = true
                        }
                        .alert("社内ルールをすべて削除して空にします。\nよろしいですか?",
                               isPresented: $confirmClearNaiki) {
                            Button("キャンセル", role: .cancel) {}
                            Button("削除", role: .destructive) { store.saveNaiki("") }
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

                Section {
                    Toggle("🛠 開発モード", isOn: $store.devMode)
                        .tint(Theme.accent)
                } footer: {
                    Text("オンにすると、APIが担当者役(会計の素人)になり、聞き返しへの返答や回答への更問(追加質問)を自動で行います。その他の挙動は変わりません。")
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
            // 入力欄の外をタップするとキーボードを閉じる。
            // キーボード表示中だけジェスチャーを有効にする(通常時はボタンのタップを一切妨げない)
            .simultaneousGesture(
                TapGesture().onEnded { styleFocused = false },
                including: styleFocused ? .all : .subviews
            )
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
                showSampleNote(n > 0 ? "サンプル相談を\(n)件追加しました。"
                    : "サンプルは既に追加済みのため、メッセージ・案件の状態を初期状態に修復しました。")
            } catch {
                showSampleNote("追加に失敗しました: \(error.localizedDescription)")
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
                showManualNote("✓「\(title)」を追加しました。")
            } catch {
                showManualNote("追加に失敗しました: \(error.localizedDescription)")
            }
            manualBusy = nil
        }
    }

    /// マニュアル追加の実行結果を一度だけ表示し、数秒で自動的に消す
    private func showManualNote(_ text: String) {
        manualNote = text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { if manualNote == text { manualNote = nil } }
        }
    }

    /// 実行結果を一度だけ表示し、数秒で自動的に消す
    private func showSampleNote(_ text: String) {
        sampleNote = text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { if sampleNote == text { sampleNote = nil } }
        }
    }

    private func deleteAllRooms() {
        deleteAllBusy = true
        Task {
            do {
                try await store.deleteAllRooms()
                showSampleNote("すべての相談を削除しました。")
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
