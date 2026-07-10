import SwiftUI

/// BAタブ: エスカレーション案件の一覧と回答フロー
struct ExpertView: View {
    @EnvironmentObject var store: CloudStore

    private var orderedCases: [CaseItem] {
        let visible = store.visibleCases
        let open = visible.filter { $0.status != .answered }
        let done = visible.filter { $0.status == .answered }
        return open + done
    }

    /// 自分が対応者になっていない未回答案件があるか(案内バナーの表示判定)
    private var showHandlerHint: Bool {
        let me = store.myName()
        return orderedCases.contains { $0.status != .answered && !(!me.isEmpty && $0.handledBy == me) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if orderedCases.isEmpty {
                            Text("BAへの確認依頼はありません。\nAIが回答できない質問が届くとここに表示されます。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 40)
                        }
                        if showHandlerHint {
                            Text("回答するには「要対応」をタップして、自分を対応者にしてください。")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.tagPendingFg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(red: 1.0, green: 0xf8 / 255.0, blue: 0xe1 / 255.0))
                                .cornerRadius(8)
                        }
                        ForEach(orderedCases) { c in
                            CaseCardView(caseItem: c,
                                         highlighted: store.highlightCaseId == c.id)
                                .id(c.id)
                        }
                    }
                    .padding(12)
                }
                .background(Theme.panelBg)
                // タブの初回表示時は onChange が発火しないため、onAppear でもスクロールする
                .onAppear { scrollToHighlight(proxy) }
                .onChange(of: store.highlightCaseId) { _ in scrollToHighlight(proxy) }
            }
            .navigationTitle("BA")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 該当案件が一番上にくるようにスクロール(レイアウト確定を待ってから)
    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        guard let id = store.highlightCaseId else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            // ハイライトは2秒で解除(Web版 jump-hl と同様)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if store.highlightCaseId == id { store.highlightCaseId = nil }
        }
    }
}

struct CaseCardView: View {
    @EnvironmentObject var store: CloudStore
    @StateObject private var speech = SpeechRecognizer()
    let caseItem: CaseItem
    var highlighted = false

    @State private var customSelected = false
    @State private var customDirection = ""
    /// マニュアル引用のタップで開くプレビュー(マニュアルとハイライト対象を1つの値で渡す。
    /// 別々の@Stateにすると初回表示でハイライトが未設定のままシートが描画される)
    struct ManualPreviewTarget: Identifiable {
        let id = UUID()
        let manual: Manual
        let excerpt: String
    }
    @State private var previewTarget: ManualPreviewTarget?
    @State private var draftText = ""
    @State private var isEditingDraft = false
    @State private var generating = false
    @State private var checkingRefs = false
    @State private var errorMessage: String?

    /// 自分が対応者になっている案件だけ、選択肢の選択〜回答の送信ができる
    private var mineHandling: Bool {
        let me = store.myName()
        return !me.isEmpty && caseItem.handledBy == me
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLabel

            Text(caseItem.question)
                .font(.system(size: 15, weight: .semibold))
                .lineSpacing(3)
                .multilineTextAlignment(.leading)

            if caseItem.status == .answered {
                noteBox("📨 送信済み回答:\n\(caseItem.answer ?? "")", bg: Theme.tagDoneBg)
            } else {
                pendingBody
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(highlighted ? Theme.accent.opacity(0.6) : .clear, lineWidth: 3)
        )
        .sheet(item: $previewTarget) { target in
            ManualPreviewSheet(manual: target.manual, highlight: target.excerpt)
        }
        .onChange(of: speech.transcript) { t in
            if speech.isRecording { customDirection = t }
        }
        .onChange(of: caseItem.draft) { d in
            if let d, !isEditingDraft { draftText = d }
        }
        .onAppear { draftText = caseItem.draft ?? "" }
    }

    // ステータス＋対応者を統合したラベル(要対応 / 対応中：対応者 / 対応済み：対応者)
    // 未回答はタップで自分を対応者にON/OFF(トグル)できる
    @ViewBuilder
    private var statusLabel: some View {
        if caseItem.status == .answered {
            labelChip("✓ 対応済み" + (caseItem.handledBy.isEmpty ? "" : "：\(caseItem.handledBy)"), bg: Theme.accent)
        } else {
            Button {
                store.toggleHandler(caseItem)
            } label: {
                if caseItem.handledBy.isEmpty {
                    labelChip("要対応", bg: Color(red: 0xd6 / 255.0, green: 0x3a / 255.0, blue: 0x2f / 255.0))       // 赤
                } else {
                    labelChip("対応中：\(caseItem.handledBy)", bg: Color(red: 0xe8 / 255.0, green: 0x8a / 255.0, blue: 0x1a / 255.0)) // オレンジ
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func labelChip(_ text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .cornerRadius(4)
    }

    @ViewBuilder
    private var pendingBody: some View {
        // 各選択肢に対応するマニュアルの該当箇所(確認済みなら選択肢の下に表示)
        let refsByOpt = Dictionary(grouping: caseItem.manualRefs ?? [], by: { $0.option })

        ForEach(Array(caseItem.options.enumerated()), id: \.offset) { i, opt in
            optionCard(index: i, text: opt, refs: refsByOpt[i] ?? [])
        }

        customOptionCard

        // マニュアルの該当箇所の確認(対応者でなくても実行可。結果は案件に保存され全員に表示)
        if !store.manuals.isEmpty {
            if caseItem.manualRefs == nil {
                Button {
                    fetchRefs()
                } label: {
                    if checkingRefs {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("確認中...")
                        }
                        .font(.system(size: 13))
                    } else {
                        Text("📖 マニュアルの該当箇所を確認")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(checkingRefs)
            } else if caseItem.manualRefs?.isEmpty == true {
                Text("📖 マニュアルに該当箇所はありません。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }

        if let errorMessage {
            Text("⚠ \(errorMessage)")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }

        if mineHandling {
            HStack {
                Spacer()
                Button {
                    generateDraft()
                } label: {
                    if generating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("作成中...")
                        }
                    } else {
                        Text("回答文(案)を作成")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(generating)
            }

            if caseItem.status == .drafted, caseItem.draft != nil {
                Text("回答文(案) — 編集できます:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextEditor(text: $draftText)
                    .font(.system(size: 13))
                    .frame(minHeight: 140)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
                    .onChange(of: draftText) { _ in isEditingDraft = true }

                HStack {
                    Button("作り直す") {
                        generateDraft()
                    }
                    .buttonStyle(.bordered)
                    .disabled(generating)

                    Spacer()

                    Button("OK — 質問者に送信") {
                        store.updateCase(caseItem.id, ["draft": draftText]) // 編集を保存
                        store.approveCase(caseItem, finalText: draftText)
                        isEditingDraft = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func optionCard(index: Int, text: String, refs: [ManualRef]) -> some View {
        let selected = !customSelected && caseItem.selectedOption == index
        return Button {
            guard mineHandling else { return }
            customSelected = false
            store.updateCase(caseItem.id, ["selectedOption": index])
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Theme.accent : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                        // タップで該当マニュアルのプレビューを開く
                        Button {
                            if let m = store.manuals.first(where: { $0.title == ref.manual }) {
                                previewTarget = ManualPreviewTarget(manual: m, excerpt: ref.excerpt)
                            }
                        } label: {
                            Text("📖 \(ref.manual): \(ref.excerpt)")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.tagWaitingFg)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(Color(red: 0xee / 255, green: 0xf4 / 255, blue: 1.0))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.accent : Color(.separator), lineWidth: 1.5)
            )
            .background(selected ? Theme.accent.opacity(0.06) : .clear)
            .opacity(mineHandling ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    /// 自由入力も選択肢と同じカード形式(タップで入力フォームが開く。音声入力可)
    private var customOptionCard: some View {
        Button {
            guard mineHandling else { return }
            customSelected = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: customSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(customSelected ? Theme.accent : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("自由に入力する(音声入力できます)")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                    if customSelected {
                        TextEditor(text: $customDirection)
                            .font(.system(size: 13))
                            .frame(minHeight: 70)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 1))
                        Button {
                            toggleVoice()
                        } label: {
                            Label(speech.isRecording ? "● 停止" : "音声入力", systemImage: "mic.fill")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.bordered)
                        .tint(speech.isRecording ? .red : .secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(customSelected ? Theme.accent : Color(.separator), lineWidth: 1.5)
            )
            .background(customSelected ? Theme.accent.opacity(0.06) : .clear)
            .opacity(mineHandling ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    private func noteBox(_ text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(bg)
            .cornerRadius(8)
    }

    private func toggleVoice() {
        if speech.isRecording {
            speech.stop()
            return
        }
        Task {
            let ok = await speech.start(base: customDirection)
            if !ok { errorMessage = "音声入力を開始できませんでした(マイク・音声認識の許可を確認してください)。" }
        }
    }

    private func fetchRefs() {
        checkingRefs = true
        errorMessage = nil
        Task {
            do {
                try await store.fetchManualRefs(for: caseItem)
            } catch {
                errorMessage = "マニュアルの確認に失敗しました: \(error.localizedDescription)"
            }
            checkingRefs = false
        }
    }

    private func generateDraft() {
        // 回答方針: 自由入力があればそれを優先、なければ選択した選択肢
        let custom = customDirection.trimmingCharacters(in: .whitespacesAndNewlines)
        let direction = !custom.isEmpty
            ? custom
            : (caseItem.selectedOption.flatMap { caseItem.options.indices.contains($0) ? caseItem.options[$0] : nil } ?? "")
        guard !direction.isEmpty else {
            errorMessage = "回答方針を選択するか、音声/テキストで入力してください。"
            return
        }
        if speech.isRecording { speech.stop() }
        errorMessage = nil
        generating = true
        isEditingDraft = false
        Task {
            do {
                try await store.generateDraft(for: caseItem, direction: direction)
            } catch {
                errorMessage = "回答案の作成に失敗しました: \(error.localizedDescription)"
            }
            generating = false
        }
    }
}
