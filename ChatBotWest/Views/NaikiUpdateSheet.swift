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

    @State private var text = ""
    @State private var busy = false
    @State private var savedNote: String?
    @State private var errorMessage: String?
    @State private var confirmApply = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("内容を確認・編集して「\(applyLabel)」で反映します。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ZStack(alignment: .center) {
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
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
            .confirmationDialog(confirmBeforeApply ?? "", isPresented: $confirmApply, titleVisibility: .visible) {
                Button("反映する") { doApply() }
                Button("キャンセル", role: .cancel) {}
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
        savedNote = savedMessage
    }
}
