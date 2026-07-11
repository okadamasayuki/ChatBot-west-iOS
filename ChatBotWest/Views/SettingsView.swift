import SwiftUI
import UIKit
import PhotosUI
import Combine

/// プロフィール設定: ニックネーム / アイコン(絵文字・写真・AI生成)
struct IconSettingView: View {
    @EnvironmentObject var store: CloudStore
    @State private var photosItem: PhotosPickerItem?
    @State private var aiPrompt = ""
    @State private var aiBusy = false
    @State private var aiPreview: UIImage?
    @State private var errorMessage: String?
    @State private var nicknameText = ""
    @State private var nicknameSaved = false
    @FocusState private var nicknameFocused: Bool

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

            Section("氏名") {
                HStack {
                    TextField("氏名", text: $nicknameText)
                        .focused($nicknameFocused)
                        .submitLabel(.done)
                        .onSubmit { saveNickname() }
                    if nicknameSaved {
                        Text("✓ 保存しました").font(.footnote).foregroundColor(.secondary)
                    } else if nicknameText.trimmingCharacters(in: .whitespaces) != store.nickname,
                              !nicknameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("保存") { saveNickname() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                }
            }

            Section("写真から選ぶ") {
                PhotosPicker(selection: $photosItem, matching: .images) {
                    Label("写真を選択", systemImage: "photo")
                }
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
        .navigationTitle("プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nicknameText = store.nickname.isEmpty ? store.myName() : store.nickname }
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

    private func saveNickname() {
        let trimmed = nicknameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.saveNickname(trimmed)
        nicknameFocused = false
        nicknameSaved = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { nicknameSaved = false }
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

/// 組織の選択肢(会社・部署・担当)の編集。財務のみ。全ユーザーに同期される
struct OrgSettingsView: View {
    @EnvironmentObject var store: CloudStore
    @State private var newCompany = ""
    @State private var newDepartment = ""
    @State private var newSection = ""
    @State private var sectionDept = ""
    @State private var sectionCompany = ""

    @State private var deptCompany = ""

    var body: some View {
        Form {
            Section {
                ForEach(store.orgCompanies, id: \.self) { c in
                    SwipeDeleteRow(onDelete: { deleteCompany(c) }) {
                        Text(c)
                    }
                }
                .onMove { from, to in
                    // 並び順は新規登録の会社選択肢にもそのまま反映される
                    store.orgCompanies.move(fromOffsets: from, toOffset: to)
                    store.saveOrgConfig()
                }
                addRow(placeholder: "会社を追加", text: $newCompany) {
                    let name = newCompany.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !store.orgCompanies.contains(name) else { return }
                    store.orgCompanies.append(name)
                    store.orgDepartments[name] = []
                    store.saveOrgConfig()
                    newCompany = ""
                }
            } header: {
                Text("会社")
            }

            Section("部署") {
                Picker("会社", selection: $deptCompany) {
                    ForEach(store.orgCompanies, id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
                .pickerStyle(.menu)
                ForEach(store.departments(for: deptCompany), id: \.self) { d in
                    SwipeDeleteRow(onDelete: { deleteDepartment(d) }) {
                        Text(d)
                    }
                }
                addRow(placeholder: "部署を追加", text: $newDepartment) {
                    let name = newDepartment.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !deptCompany.isEmpty else { return }
                    var list = store.departments(for: deptCompany)
                    guard !list.contains(name) else { newDepartment = ""; return }
                    list.append(name)
                    store.orgDepartments[deptCompany] = list
                    store.saveOrgConfig()
                    newDepartment = ""
                }
            }

            Section("担当") {
                // 担当は会社+部署に紐づく
                Picker("会社", selection: $sectionCompany) {
                    ForEach(store.orgCompanies, id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: sectionCompany) { c in
                    sectionDept = store.departments(for: c).first ?? ""
                }
                Picker("部署", selection: $sectionDept) {
                    ForEach(store.departments(for: sectionCompany), id: \.self) { d in
                        Text(d).tag(d)
                    }
                }
                .pickerStyle(.menu)
                ForEach(store.sections(company: sectionCompany, department: sectionDept), id: \.self) { s in
                    SwipeDeleteRow(onDelete: { deleteSection(s) }) {
                        Text(s)
                    }
                }
                addRow(placeholder: "担当を追加", text: $newSection) {
                    let name = newSection.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !sectionCompany.isEmpty, !sectionDept.isEmpty else { return }
                    let key = CloudStore.sectionKey(sectionCompany, sectionDept)
                    var list = store.orgSections[key] ?? []
                    guard !list.contains(name) else { newSection = ""; return }
                    list.append(name)
                    store.orgSections[key] = list
                    store.saveOrgConfig()
                    newSection = ""
                }
            }
        }
        .navigationTitle("組織の設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if deptCompany.isEmpty { deptCompany = store.orgCompanies.first ?? "" }
            if sectionCompany.isEmpty { sectionCompany = store.orgCompanies.first ?? "" }
            if sectionDept.isEmpty { sectionDept = store.departments(for: sectionCompany).first ?? "" }
        }
    }

    private func deleteCompany(_ c: String) {
        // 会社を消したらその会社の部署・担当リストも消す
        for d in store.departments(for: c) {
            store.orgSections[CloudStore.sectionKey(c, d)] = nil
        }
        store.orgDepartments[c] = nil
        store.orgCompanies.removeAll { $0 == c }
        if !store.orgCompanies.contains(deptCompany) {
            deptCompany = store.orgCompanies.first ?? ""
        }
        if !store.orgCompanies.contains(sectionCompany) {
            sectionCompany = store.orgCompanies.first ?? ""
            sectionDept = store.departments(for: sectionCompany).first ?? ""
        }
        store.saveOrgConfig()
    }

    private func deleteDepartment(_ d: String) {
        // その会社の部署の担当リストも消す
        store.orgSections[CloudStore.sectionKey(deptCompany, d)] = nil
        store.orgDepartments[deptCompany] = store.departments(for: deptCompany).filter { $0 != d }
        if sectionCompany == deptCompany, sectionDept == d {
            sectionDept = store.departments(for: sectionCompany).first ?? ""
        }
        store.saveOrgConfig()
    }

    private func deleteSection(_ s: String) {
        let key = CloudStore.sectionKey(sectionCompany, sectionDept)
        store.orgSections[key] = (store.orgSections[key] ?? []).filter { $0 != s }
        store.saveOrgConfig()
    }

    private func addRow(placeholder: String, text: Binding<String>, onAdd: @escaping () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .submitLabel(.done)
                .onSubmit(onAdd)
            Button("追加", action: onAdd)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// 左にスライドすると赤い四角形の削除ボタンが指に追従して滑らかに出てくる行
/// (OS標準のスワイプ削除はボタンが丸く表示されるため自作)
/// leadingIcon を指定すると、右スライドで左側のアクション(ピン留めなど)も出せる
struct SwipeDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    var deleteIcon = "trash.fill"
    var leadingIcon: String? = nil
    var leadingColor = Color(red: 0x33 / 255.0, green: 0xa1 / 255.0, blue: 0xde / 255.0)
    var onLeading: (() -> Void)? = nil
    var contentInsets = EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 0)
    @ViewBuilder var content: () -> Content
    @State private var width: CGFloat = 0       // 削除ボタンの見えている幅(ドラッグに追従)
    @State private var leadWidth: CGFloat = 0   // 左側アクションの見えている幅
    @State private var opened = false
    @State private var leadOpened = false
    @State private var rowId = UUID()
    @State private var postedOpenSignal = false

    private let full: CGFloat = 72
    /// どこかの行に触れたら、他の行の開いているスライドを閉じるための合図
    private static var closeAllNotification: Notification.Name { Notification.Name("SwipeDeleteRowCloseAll") }

    var body: some View {
        // 行本体は幅を変えずに横へスライドさせる(圧縮すると折り返しが増えて行が高くなるため)。
        // ボタンは背面に固定幅で置き、本体がずれた分だけ見える
        content()
            .padding(contentInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .overlay {
                // 開いている間は行本体のタップを吸収して、閉じるだけにする(LINEと同じ)
                if opened || leadOpened {
                    Color.black.opacity(0.001)
                        .onTapGesture { closeAll() }
                }
            }
            .offset(x: leadWidth - width)
            .background {
                HStack(spacing: 0) {
                    if let leadingIcon, let onLeading {
                        Button {
                            closeAll()
                            onLeading()
                        } label: {
                            Rectangle()
                                .fill(leadingColor)
                                .overlay(
                                    Image(systemName: leadingIcon)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white)
                                        .opacity(leadWidth > 30 ? 1 : 0)
                                )
                        }
                        .buttonStyle(.borderless)
                        .frame(width: leadWidth)
                        .clipped()
                    }
                    Spacer(minLength: 0)
                    Button {
                        closeAll()
                        onDelete()
                    } label: {
                        Rectangle()
                            .fill(Color.red) // 四角形・赤。行の上下(区切り線)いっぱいに広がる
                            .overlay(
                                Image(systemName: deleteIcon)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                    .opacity(width > 30 ? 1 : 0)
                            )
                    }
                    .buttonStyle(.borderless)
                    .frame(width: width)
                    .clipped()
                }
            }
        .listRowInsets(EdgeInsets())
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // 行のどこかに触れたら、他の行の開いているスライドを閉じる
            NotificationCenter.default.post(name: Self.closeAllNotification, object: rowId)
        })
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    if !postedOpenSignal {
                        postedOpenSignal = true
                        NotificationCenter.default.post(name: Self.closeAllNotification, object: rowId)
                    }
                    if leadOpened || (v.translation.width > 0 && !opened) {
                        guard leadingIcon != nil, onLeading != nil else { return }
                        let base: CGFloat = leadOpened ? full : 0
                        leadWidth = max(0, min(full + 12, base + v.translation.width))
                    } else {
                        let base: CGFloat = opened ? full : 0
                        width = max(0, min(full + 12, base - v.translation.width))
                    }
                }
                .onEnded { _ in
                    postedOpenSignal = false
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        opened = width > full * 0.5
                        width = opened ? full : 0
                        leadOpened = leadWidth > full * 0.5
                        leadWidth = leadOpened ? full : 0
                    }
                }
        )
        .onReceive(NotificationCenter.default.publisher(for: Self.closeAllNotification)) { note in
            // 他の行がスライド・タップされたら自分は閉じる
            guard note.object as? UUID != rowId, opened || leadOpened || width > 0 || leadWidth > 0 else { return }
            closeAll()
        }
    }

    private func closeAll() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            width = 0; opened = false
            leadWidth = 0; leadOpened = false
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
    @State private var baTalkBusy = false

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
                            Text("サンプル相談を追加")
                        }
                    }
                    .disabled(sampleBusy)
                    if store.isExpert {
                        Button {
                            addSampleBaTalks()
                        } label: {
                            HStack {
                                if baTalkBusy { ProgressView().padding(.trailing, 6) }
                                Text("サンプルBAチャットを追加")
                            }
                        }
                        .disabled(baTalkBusy)
                    }
                    // サンプルマニュアルはタップ→一覧から選んで追加
                    Menu {
                        ForEach(Self.sampleManuals, id: \.slug) { item in
                            Button("📄 \(item.title)") {
                                addSampleManual(item.slug, item.title)
                            }
                        }
                    } label: {
                        HStack {
                            if manualBusy != nil { ProgressView().padding(.trailing, 6) }
                            Text("サンプルマニュアルを追加")
                                .foregroundColor(Theme.accentDark)
                        }
                    }
                    .disabled(manualBusy != nil)
                    if let sampleNote {
                        Text(sampleNote).font(.footnote).foregroundColor(.secondary)
                    }
                }

                if store.isExpert {
                    Section("🏢 組織") {
                        NavigationLink("会社・部署・担当を編集") {
                            OrgSettingsView()
                        }
                    }

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

                if store.isExpert {
                    Section {
                        Toggle("🛠 開発モード", isOn: $store.devMode)
                            .tint(Theme.accent)
                    } footer: {
                        Text("オンにすると、APIが担当者役(会計の素人)になり、聞き返しへの返答や回答への更問(追加質問)を自動で行います。その他の挙動は変わりません。")
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

    private func addSampleBaTalks() {
        baTalkBusy = true
        Task {
            do {
                let n = try await SampleData.addSampleBaTalks(store: store)
                showSampleNote(n > 0 ? "サンプルBAチャットを\(n)件追加しました。"
                    : "サンプルBAチャットは既に追加済みのため、メッセージを初期状態に修復しました。")
            } catch {
                showSampleNote("追加に失敗しました: \(error.localizedDescription)")
            }
            baTalkBusy = false
        }
    }

    private func addSampleManual(_ slug: String, _ title: String) {
        manualBusy = slug
        Task {
            do {
                try await SampleData.addSampleManual(slug: slug, title: title, store: store)
                showSampleNote("✓「\(title)」を追加しました。")
            } catch {
                showSampleNote("追加に失敗しました: \(error.localizedDescription)")
            }
            manualBusy = nil
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
