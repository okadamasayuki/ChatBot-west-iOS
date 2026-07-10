import SwiftUI

/// LINE風チャット画面
struct ChatRoomView: View {
    @EnvironmentObject var store: CloudStore
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var lastMessageId: String? {
        store.pendingTyping ? "typing" : store.roomMessages.last?.id
    }

    private var room: Room? { store.currentRoom() }

    /// 財務、および他人の相談を開いた担当者は閲覧のみ
    private var viewOnly: Bool { !store.canSendInCurrentRoom }

    /// 他人の相談を閲覧しているときは、質問メッセージに相談者名を表示
    private var ownerName: String {
        guard let r = room, !store.isMyRoom(r) else { return "" }
        return r.ownerName.isEmpty ? r.ownerEmail : r.ownerName
    }

    /// 完了の切り替えは財務と相談の本人のみ(未保存の新規相談には出さない)
    private var canToggleDone: Bool {
        guard let r = room, store.pendingRoom?.id != r.id else { return false }
        return store.isExpert || store.isMyRoom(r)
    }

    /// メッセージの表示スタイル(LINEと同じく「自分側=右・緑」の視点で描く)。
    /// 財務: AI/BAが右側(BAは緑)、質問者が左側。担当者: 自分の質問が右・緑、AI/BAが左側
    private func bubbleStyle(for msg: Message) -> (label: String?, right: Bool, color: Color, border: Color?) {
        let questionerName = ownerName.isEmpty ? "質問者" : ownerName
        if store.isExpert {
            switch msg.role {
            case .user:
                return ("🙋 \(questionerName)", false, Color(.systemBackground), nil)
            case .ai:
                return ("🤖 AIアシスタント", true, Color(.systemBackground), nil)
            default:
                return ("👤 BA", true, Theme.myBubble, nil)
            }
        } else {
            switch msg.role {
            case .user:
                return (ownerName.isEmpty ? nil : "🙋 \(ownerName)", true, Theme.myBubble, nil)
            case .ai:
                return ("🤖 AIアシスタント", false, Color(.systemBackground), nil)
            default:
                return ("👤 BA", false, Theme.expertBubble, Theme.expertBorder)
            }
        }
    }

    /// 自分側のメッセージの既読/未読(相手が読んだかどうか)。
    /// 相談の本人には自分の質問、財務にはBAの回答に対して表示する
    private func readStatus(for msg: Message) -> String? {
        guard let r = room else { return nil }
        if store.isMyRoom(r) {
            guard msg.role == .user else { return nil }
            // 自分以外の誰か(財務など)が読んだか
            let read = r.reads.contains { $0.key != store.myUid() && $0.value >= msg.ts }
            return read ? "既読" : "未読"
        } else if store.isExpert {
            guard msg.role == .expert else { return nil }
            // 相談の本人が読んだか
            let read = r.ownerUid.isEmpty
                ? r.reads.contains { $0.key != store.myUid() && $0.value >= msg.ts }
                : (r.reads[r.ownerUid] ?? "") >= msg.ts
            return read ? "既読" : "未読"
        }
        return nil
    }

    /// この相談の未回答案件(財務のみ、チャット内にBAの案件カードを統合表示する)
    private var roomCases: [CaseItem] {
        guard store.isExpert, let id = store.currentRoomId, !store.isDoneRoom(id) else { return [] }
        return store.cases.filter { $0.roomId == id && $0.status != .answered }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.roomMessages.isEmpty && !store.pendingTyping {
                            SystemBubble(text: "会計に関する質問を入力してください。AIが回答できない場合はBAにおつなぎします。")
                        }
                        let lastIdx = store.roomMessages.count - 1
                        ForEach(Array(store.roomMessages.enumerated()), id: \.element.id) { idx, msg in
                            let style = bubbleStyle(for: msg)
                            MessageBubble(
                                message: msg,
                                senderLabel: style.label,
                                alignRight: style.right,
                                bubbleColor: style.color,
                                borderColor: style.border,
                                readStatus: readStatus(for: msg),
                                showClarify: idx == lastIdx && msg.role == .ai && !msg.clarifyOptions.isEmpty && !viewOnly,
                                onChoice: { choice in
                                    Task { await store.submitQuestion(choice) }
                                }
                            )
                            .id(msg.id)
                        }
                        if store.pendingTyping {
                            TypingBubble().id("typing")
                        }
                        // BAタブの該当案件をチャット内に統合表示(財務のみ・未回答の案件)
                        ForEach(roomCases) { c in
                            CaseCardView(caseItem: c)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .background(Theme.chatBg)
                .onChange(of: lastMessageId) { id in
                    if let id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onTapGesture { inputFocused = false }
            }

            if !viewOnly {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("会計に関する質問を入力...", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.systemBackground))
                        .cornerRadius(18)
                        .focused($inputFocused)

                    Button {
                        let text = input
                        input = ""
                        Task { await store.submitQuestion(text) }
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                            .frame(width: 42, height: 42)
                            .background(store.sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Theme.accent.opacity(0.4) : Theme.accent)
                            .clipShape(Circle())
                    }
                    .disabled(store.sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
            }
        }
        .navigationTitle(room?.title ?? "相談")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canToggleDone {
                    Button {
                        if let id = store.currentRoomId { store.toggleRoomDone(id) }
                    } label: {
                        Text(room?.isDone == true ? "✓ 完了" : "完了にする")
                            .font(.system(size: 13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(room?.isDone == true ? Theme.accent : Color(.secondarySystemBackground))
                            .foregroundColor(room?.isDone == true ? .white : .primary)
                            .cornerRadius(8)
                    }
                }
            }
        }
    }
}

// MARK: - バブル

struct MessageBubble: View {
    let message: Message
    var senderLabel: String? = nil
    var alignRight = false
    var bubbleColor: Color = Color(.systemBackground)
    var borderColor: Color? = nil
    var readStatus: String? = nil
    let showClarify: Bool
    var onChoice: (String) -> Void = { _ in }

    var body: some View {
        if message.role == .system {
            SystemBubble(text: message.text)
        } else {
            HStack {
                if alignRight { Spacer(minLength: 60) }
                VStack(alignment: alignRight ? .trailing : .leading, spacing: 3) {
                    if let senderLabel {
                        Text(senderLabel)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.header.opacity(0.8))
                    }
                    bubbleText
                        .background(bubbleColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(borderColor ?? .clear, lineWidth: 1)
                        )
                        .cornerRadius(14)
                    if showClarify {
                        // 聞き返しの選択肢ボタン
                        FlowChoices(options: message.clarifyOptions, onChoice: onChoice)
                    }
                    HStack(spacing: 4) {
                        // LINEと同じく、自分側は「既読 → 時刻」の順
                        if alignRight { readStatusText }
                        timeText
                        if !alignRight { readStatusText }
                    }
                }
                if !alignRight { Spacer(minLength: 60) }
            }
        }
    }

    @ViewBuilder
    private var readStatusText: some View {
        if let readStatus {
            Text(readStatus)
                .font(.system(size: 10))
                .foregroundColor(readStatus == "既読" ? Theme.accentDark : Theme.header.opacity(0.6))
        }
    }

    private var bubbleText: some View {
        Text(message.text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    private var timeText: some View {
        Text(fmtTime(message.ts))
            .font(.system(size: 10))
            .foregroundColor(Theme.header.opacity(0.6))
    }
}

/// 聞き返し選択肢
struct FlowChoices: View {
    let options: [String]
    let onChoice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { opt in
                Button {
                    onChoice(opt)
                } label: {
                    Text(opt)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.accentDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(.systemBackground))
                        .overlay(Capsule().stroke(Theme.accent, lineWidth: 1.5))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.top, 2)
    }
}

struct SystemBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.header.opacity(0.55))
            .cornerRadius(10)
            .frame(maxWidth: .infinity)
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("🤖 AIアシスタント")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.header.opacity(0.8))
                TimelineView(.periodic(from: .now, by: 0.4)) { context in
                    let active = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 6, height: 6)
                                .opacity(active == i ? 1 : 0.3)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color(.systemBackground))
                .cornerRadius(14)
            }
            Spacer(minLength: 60)
        }
    }
}
