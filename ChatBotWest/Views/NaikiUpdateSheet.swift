import SwiftUI

/// 「相談から社内ルールを更新」「マニュアルから社内ルールを抽出」「コンパクト」で共通のシート。
/// 開くとAIが抽出/整理した案を表示し、編集して反映できる(Web版のモーダルと同じ流れ)。
struct NaikiUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// AIによる抽出/整理(再抽出でも呼ばれる)
    let extract: () async throws -> String
    /// 「反映」ボタンで呼ばれる(追記 or 置き換えは呼び出し側が決める)
    let apply: (String) -> Void
    var savedMessage: String
    var applyLabel: String = "社内ルールに追加"
    var confirmBeforeApply: String? = nil
    /// 変更前のテキスト。指定すると「差分/編集」の切り替え表示になる(コンパクト用)
    var diffBase: String? = nil
    /// 反映したらシートを閉じる
    var dismissOnApply = false

    @State private var text = ""
    @State private var busy = false
    @State private var savedNote: String?
    @State private var errorMessage: String?
    @State private var confirmApply = false
    @State private var showDiff = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("内容を確認・編集して「\(applyLabel)」で反映します。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if diffBase != nil {
                    Picker("表示", selection: $showDiff) {
                        Text("差分").tag(true)
                        Text("編集").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                ZStack(alignment: .center) {
                    if let base = diffBase, showDiff, !busy {
                        DiffView(old: base, new: text)
                    } else {
                        TextEditor(text: $text)
                            .font(.system(size: 13))
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
                    }
                    if busy {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("AIが抽出中…").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }

                if let savedNote {
                    Text(savedNote).font(.footnote).foregroundColor(Theme.accentDark)
                }
                if let errorMessage {
                    Text("⚠ \(errorMessage)").font(.footnote).foregroundColor(.red)
                }

                HStack {
                    Button("再抽出") { runExtract() }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    Spacer()
                    Button(applyLabel) {
                        if confirmBeforeApply != nil { confirmApply = true }
                        else { doApply() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(busy || !canApply)
                }
            }
            .padding(14)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert(confirmBeforeApply ?? "", isPresented: $confirmApply) {
                Button("キャンセル", role: .cancel) {}
                Button("反映する") { doApply() }
            }
        }
        .task { runExtract() }
    }

    private var canApply: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.contains(Prompts.noDiffText)
    }

    private func runExtract() {
        busy = true
        savedNote = nil
        errorMessage = nil
        Task {
            do {
                text = try await extract()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func doApply() {
        guard canApply else { return }
        apply(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if dismissOnApply {
            dismiss()
        } else {
            savedNote = savedMessage
        }
    }
}

// MARK: - 行単位の差分表示(変更前=赤 / 変更後=緑)

struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(LineDiff.diff(old, new)) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(line.op == .added ? "+" : line.op == .removed ? "−" : " ")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(line.op == .added ? Theme.tagDoneFg
                                             : line.op == .removed ? .red : .secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12))
                            .foregroundColor(line.op == .removed ? Color.red.opacity(0.85) : .primary)
                            .strikethrough(line.op == .removed, color: .red.opacity(0.5))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        line.op == .added ? Theme.tagDoneBg
                            : line.op == .removed ? Color.red.opacity(0.08) : Color.clear
                    )
                }
            }
            .padding(6)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
    }
}

enum LineDiff {
    enum Op { case same, added, removed }

    struct Line: Identifiable {
        let id = UUID()
        let op: Op
        let text: String
    }

    /// LCS(最長共通部分列)による行単位の差分
    static func diff(_ old: String, _ new: String) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(Line(op: .same, text: a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                result.append(Line(op: .removed, text: a[i])); i += 1
            } else {
                result.append(Line(op: .added, text: b[j])); j += 1
            }
        }
        while i < n { result.append(Line(op: .removed, text: a[i])); i += 1 }
        while j < m { result.append(Line(op: .added, text: b[j])); j += 1 }
        return result
    }
}
