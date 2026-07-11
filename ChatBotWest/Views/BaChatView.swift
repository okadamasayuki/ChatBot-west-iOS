import SwiftUI

/// BAチャット: 財務(BA)同士のグループチャット。相談チャットへのリンクを貼れる
struct BaChatView: View {
    @EnvironmentObject var store: CloudStore
    @State private var input = ""
    @State private var showRoomPicker = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if store.baMessages.isEmpty {
                                Text("BA同士の連絡用チャットです。\n📎 から相談チャットのリンクを貼れます。")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.header.opacity(0.55))
                                    .cornerRadius(10)
                            }
                            ForEach(store.baMessages) { msg in
                                BaMessageBubble(message: msg, isMine: msg.senderUid == store.myUid())
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                    }
                    .background(Theme.chatBg)
                    .onChange(of: store.baMessages.last?.id) { id in
                        if let id {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let id = store.baMessages.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .onTapGesture { inputFocused = false }
                }

                HStack(alignment: .bottom, spacing: 8) {
                    // 相談チャットのリンクを貼る
                    Button {
                        showRoomPicker = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.accentDark)
                            .frame(width: 36, height: 42)
                    }

                    TextField("メッセージを入力...", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.systemBackground))
                        .cornerRadius(18)
                        .focused($inputFocused)

                    Button {
                        store.sendBaMessage(input)
                        input = ""
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                            .frame(width: 42, height: 42)
                            .background(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Theme.accent.opacity(0.4) : Theme.accent)
                            .clipShape(Circle())
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("BAチャット")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showRoomPicker) {
                RoomLinkPickerSheet { room in
                    store.sendBaMessage(input, roomId: room.id, roomTitle: room.title)
                    input = ""
                }
            }
        }
    }
}

/// BAチャットのバブル(自分=右・緑、他のBA=左・白+名前)
struct BaMessageBubble: View {
    @EnvironmentObject var store: CloudStore
    let message: BaMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text("👤 \(message.senderName)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.header.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                    }
                    if let roomId = message.roomId {
                        // 相談チャットへのリンクカード(タップで開く)
                        Button {
                            store.openRoomFromBaChat(roomId)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.tagWaitingFg)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(message.roomTitle?.isEmpty == false ? message.roomTitle! : "相談")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Theme.tagWaitingFg)
                                        .lineLimit(1)
                                    Text("タップして相談を開く")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Theme.tagWaitingBg)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isMine ? Theme.myBubble : Color(.systemBackground))
                .cornerRadius(14)
                .contextMenu {
                    if !message.text.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("コピー", systemImage: "doc.on.doc")
                        }
                    }
                }
                Text(fmtTime(message.ts))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.header.opacity(0.6))
            }
            if !isMine { Spacer(minLength: 60) }
        }
    }
}

/// リンクとして貼る相談を選ぶシート
struct RoomLinkPickerSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (Room) -> Void

    private var rooms: [Room] {
        store.rooms
            .filter { !$0.lastText.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.lastTs > $1.lastTs }
    }

    var body: some View {
        NavigationStack {
            List(rooms) { room in
                Button {
                    onPick(room)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.title.isEmpty ? "相談" : room.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if room.isDone {
                                TagView(text: "✓ 完了", bg: Theme.tagDoneBg, fg: Theme.tagDoneFg)
                            }
                            Text(fmtDate(room.lastTs))
                                .font(.system(size: 10))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("リンクする相談を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}
