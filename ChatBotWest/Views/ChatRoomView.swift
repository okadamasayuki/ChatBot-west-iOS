import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// LINE風チャット画面
struct ChatRoomView: View {
    @EnvironmentObject var store: CloudStore
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var editingMessage: Message?
    @State private var reviewingMessage: Message? // 安全モード: 修正して送信するAI回答
    @State private var showSummary = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photosItem: PhotosPickerItem?
    @State private var attachError: String?
    @State private var profileMember: CloudStore.MemberInfo?
    @State private var linkCopied = false
    @State private var showDelegatePicker = false
    /// 開いた直後の最下部スクロールが済んだか(以降の新着はアニメーション付きでスクロール)
    @State private var didInitialScroll = false

    /// 表示するメッセージ(財務のみ表示・安全モードの確認待ちは質問者には見せない)
    private var displayMessages: [Message] {
        store.isExpert
            ? store.roomMessages
            : store.roomMessages.filter {
                !$0.expertOnly && !$0.pendingReview
                    && !($0.role == .system && $0.text.contains("対応を依頼しました"))
            }
    }

    private var lastMessageId: String? {
        if store.devTypingRoomId != nil, store.devTypingRoomId == store.currentRoomId { return "devTyping" }
        return store.pendingTyping ? "typing" : displayMessages.last?.id
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

    /// メッセージを編集できるか(財務: AI・BAのメッセージ / 担当者: 自分の相談の自分の質問)
    private func canEdit(_ msg: Message) -> Bool {
        if store.isExpert {
            return msg.role == .ai || msg.role == .expert
        }
        guard let r = room, store.isMyRoom(r) else { return false }
        return msg.role == .user
    }

    /// メッセージの表示スタイル(LINEと同じく「自分側=右・緑」の視点で描く)。
    /// ラベルは役割名ではなくユーザー名(ニックネーム)を表示する。
    /// 財務: AI/BAが右側(BAは緑)、質問者が左側。担当者: 自分の質問が右・緑、AI/BAが左側
    private func bubbleStyle(for msg: Message) -> (label: String?, right: Bool, color: Color, border: Color?) {
        // 質問者名: メッセージの送信者名 → 相談の本人の名前 → 「質問者」
        let roomOwnerName = room.map { $0.ownerName.isEmpty ? $0.ownerEmail : $0.ownerName } ?? ""
        let questionerName = !msg.senderName.isEmpty ? msg.senderName
            : (!roomOwnerName.isEmpty ? roomOwnerName : "質問者")
        // BA名: メッセージの送信者名 → 相談の担当BA → 「BA」
        let baName = !msg.senderName.isEmpty ? msg.senderName
            : (room?.handler.isEmpty == false ? room!.handler : "BA")
        if store.isExpert {
            switch msg.role {
            case .user:
                return ("\(questionerName)", false, Color(.systemBackground), nil)
            case .ai:
                // 安全モードの確認待ちはオレンジの枠で区別する
                return ("AIアシスタント", true, Color(.systemBackground),
                        msg.pendingReview ? Self.reviewOrange : nil)
            default:
                return ("\(baName)", true, Theme.myBubble, nil)
            }
        } else {
            switch msg.role {
            case .user:
                // 自分の相談では自分のメッセージに名前は付けない(LINEと同じ)
                let isMine = room.map { store.isMyRoom($0) } ?? true
                return (isMine ? nil : "\(questionerName)", true, Theme.myBubble, nil)
            case .ai:
                return ("AIアシスタント", false, Color(.systemBackground), nil)
            default:
                return ("\(baName)", false, Theme.expertBubble, Theme.expertBorder)
            }
        }
    }

    /// 自分側のメッセージの既読/未読(相手が読んだかどうか)。
    /// 相談の本人には自分の質問、財務にはBAの回答に対して表示する
    /// 既読/未読。財務: AI/BAのメッセージに「相談の本人が読んだか」を表示。
    /// 担当者(質問者): 自分の質問に「AI/BAが読んだ・返信したか」を表示
    private func readStatus(for msg: Message) -> String? {
        guard let r = room else { return nil }
        if msg.pendingReview { return nil } // 確認待ちは未送信なので既読/未読を出さない
        if store.isExpert {
            guard msg.role == .ai || msg.role == .expert else { return nil }
            let humanRead = r.ownerUid.isEmpty || r.ownerUid == store.myUid()
                ? r.reads.contains { $0.key != store.myUid() && $0.value >= msg.ts }
                : (r.reads[r.ownerUid] ?? "") >= msg.ts
            let replied = store.roomMessages.contains { $0.role == .user && $0.ts > msg.ts }
            // 開発モードの担当者役が入力中 = 読んでいる、として既読扱いにする
            let devReading = store.devTypingRoomId == r.id
            return (humanRead || replied || devReading) ? "既読" : "未読"
        } else if store.isMyRoom(r) {
            guard msg.role == .user else { return nil }
            let humanRead = r.reads.contains { $0.key != store.myUid() && $0.value >= msg.ts }
            let replied = store.roomMessages.contains { ($0.role == .ai || $0.role == .expert) && $0.ts > msg.ts }
            return (humanRead || replied) ? "既読" : "未読"
        }
        return nil
    }

    /// メッセージの送信者のアイコン情報(未設定は役割の絵文字)と、プロフィール表示用のメンバー
    private func avatarInfo(for msg: Message) -> (data: String, icon: String, fallback: String, member: CloudStore.MemberInfo?) {
        switch msg.role {
        case .ai:
            return ("", "🤖", "", nil)
        case .expert:
            if !msg.senderName.isEmpty,
               let m = store.members.first(where: { $0.name == msg.senderName }) {
                return (m.iconData, m.iconData.isEmpty && m.icon.isEmpty ? "👤" : m.icon, "", m)
            }
            if let r = room, let m = store.members.first(where: { $0.name == r.handler }) {
                return (m.iconData, m.iconData.isEmpty && m.icon.isEmpty ? "👤" : m.icon, "", m)
            }
            return ("", "👤", "", nil)
        case .user:
            if let r = room, let m = store.member(r.ownerUid) {
                return (m.iconData, m.iconData.isEmpty && m.icon.isEmpty ? "🙋" : m.icon, "", m)
            }
            return ("", "🙋", "", nil)
        case .system:
            return ("", "", "person.fill", nil)
        }
    }

    /// この相談の未回答案件(財務のみ、チャット内にBAの案件カードを統合表示する)
    private var roomCases: [CaseItem] {
        guard store.isExpert, let id = store.currentRoomId, !store.isDoneRoom(id) else { return [] }
        return store.cases.filter { $0.roomId == id && $0.status != .answered }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            // 自分宛の対応依頼は、承諾するまで担当にならない
            if store.isExpert, let r = room, r.pendingHandler == store.myName() {
                handlerRequestBanner(r)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if displayMessages.isEmpty && !store.pendingTyping {
                            SystemBubble(text: "会計に関する質問を入力してください。AIが回答できない場合はBAにおつなぎします。")
                        }
                        let lastIdx = displayMessages.count - 1
                        ForEach(Array(displayMessages.enumerated()), id: \.element.id) { idx, msg in
                            let avatar = avatarInfo(for: msg)
                            let style = bubbleStyle(for: msg)
                            MessageBubble(
                                message: msg,
                                senderLabel: style.label,
                                alignRight: style.right,
                                bubbleColor: style.color,
                                borderColor: style.border,
                                avatarIconData: avatar.data,
                                avatarIcon: avatar.icon,
                                avatarFallback: avatar.fallback,
                                onAvatarTap: avatar.member.map { m in { profileMember = m } },
                                readStatus: msg.deleted ? nil : readStatus(for: msg),
                                myUid: store.myUid(),
                                reactionMemberFor: { uid in store.member(uid) },
                                onReaction: { emoji in store.toggleReaction(msg, emoji: emoji) },
                                showClarify: idx == lastIdx && msg.role == .ai && !msg.clarifyOptions.isEmpty && !viewOnly && !msg.deleted,
                                onChoice: { choice in
                                    Task { await store.submitQuestion(choice) }
                                },
                                // 長押しでリアクション・コピー(全メッセージ)・編集・削除・復元
                                menuContent: {
                                    AnyView(Group {
                                        if !msg.deleted {
                                            // 1列目: リアクション絵文字を1行に横並び
                                            if #available(iOS 17.0, *) {
                                                ControlGroup {
                                                    ForEach(CloudStore.reactionEmojis, id: \.self) { emoji in
                                                        Button(emoji) {
                                                            store.toggleReaction(msg, emoji: emoji)
                                                        }
                                                    }
                                                }
                                                .controlGroupStyle(.palette)
                                            } else {
                                                ControlGroup {
                                                    ForEach(CloudStore.reactionEmojis, id: \.self) { emoji in
                                                        Button(emoji) {
                                                            store.toggleReaction(msg, emoji: emoji)
                                                        }
                                                    }
                                                }
                                                .controlGroupStyle(.compactMenu)
                                            }
                                            Button {
                                                UIPasteboard.general.string = msg.text
                                            } label: {
                                                Label("コピー", systemImage: "doc.on.doc")
                                            }
                                        }
                                        if canEdit(msg) {
                                            if msg.deleted {
                                                Button {
                                                    store.restoreMessage(msg)
                                                } label: {
                                                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                                                }
                                            } else {
                                                Button {
                                                    editingMessage = msg
                                                } label: {
                                                    Label("編集", systemImage: "pencil")
                                                }
                                                Button(role: .destructive) {
                                                    store.deleteMessage(msg)
                                                } label: {
                                                    Label("削除", systemImage: "trash")
                                                }
                                            }
                                        }
                                    })
                                }
                            )
                            .id(msg.id)
                            // 安全モード: 確認待ちのAI回答には送信/修正ボタンを付ける(財務のみ)
                            if store.isExpert, msg.pendingReview, !msg.deleted {
                                pendingReviewBar(msg)
                            }
                        }
                        if store.pendingTyping {
                            // 財務視点ではAIは自分側(右)に表示
                            TypingBubble(alignRight: store.isExpert).id("typing")
                        }
                        if store.devTypingRoomId == store.currentRoomId, store.devTypingRoomId != nil {
                            // 開発モード: 担当者役が返信を生成中(質問者側に表示)
                            TypingBubble(label: "質問者が入力中…", alignRight: !store.isExpert)
                                .id("devTyping")
                        }
                        // BAタブの該当案件をチャット内に統合表示(財務のみ・未回答の案件)
                        ForEach(roomCases) { c in
                            CaseCardView(caseItem: c)
                                .padding(.top, 4)
                        }
                        // 最下部スクロールの着地点(案件カードまで含めた本当の最下部)
                        Color.clear.frame(height: 1).id("roomBottom")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .background(Theme.chatBg)
                .onChange(of: lastMessageId) { id in
                    guard id != nil else { return }
                    if didInitialScroll {
                        withAnimation { proxy.scrollTo("roomBottom", anchor: .bottom) }
                    } else {
                        // 初回ロードはLazyVStackのレイアウト確定前でscrollToが途中で止まるため、
                        // 時間差で数回に分けて最下部に合わせる
                        didInitialScroll = true
                        settleToBottom(proxy)
                    }
                }
                .onChange(of: store.currentRoomId) { _ in didInitialScroll = false }
                .onAppear { settleToBottom(proxy) }
                .onTapGesture { inputFocused = false }
            }

            if !viewOnly {
                HStack(alignment: .bottom, spacing: 8) {
                    // 写真・ファイルの添付
                    Menu {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("写真", systemImage: "photo")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("ファイル", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.accentDark)
                            .frame(width: 32, height: 42)
                    }

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
        // ヘッダーはタイトル+ボタンの1段(actionBar)にまとめ、ナビゲーションバーは使わない。
        // 戻るは相談一覧タブの再タップ・左端スワイプ
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // 送信せずに戻っても入力した文字が残るように、相談ごとに下書きを保持する
        .onAppear {
            if input.isEmpty, let id = store.currentRoomId {
                input = store.roomDrafts[id] ?? ""
            }
        }
        .onChange(of: input) { text in
            if let id = store.currentRoomId {
                store.roomDrafts[id] = text
            }
        }
        .sheet(item: $editingMessage) { msg in
            EditMessageSheet(initialText: msg.text) { newText in
                store.updateMessageText(msg, newText: newText)
            }
        }
        .sheet(item: $reviewingMessage) { msg in
            // 安全モード: 文言を修正してから質問者に送信する
            EditMessageSheet(initialText: msg.text, title: "回答を修正して送信", saveLabel: "送信") { newText in
                store.approvePendingMessage(msg, finalText: newText)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photosItem, matching: .images)
        .onChange(of: photosItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    if let jpeg = AttachmentUtils.compressImage(data) {
                        store.sendRoomAttachment(data: jpeg, name: "photo.jpg", type: "image")
                    } else {
                        attachError = "写真を圧縮できませんでした。"
                    }
                }
                photosItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                attachError = "ファイルを読み込めませんでした。"
                return
            }
            guard data.count <= AttachmentUtils.maxBytes else {
                attachError = "ファイルが大きすぎます(600KBまで)。"
                return
            }
            store.sendRoomAttachment(data: data, name: url.lastPathComponent, type: "file")
        }
        .alert("添付エラー", isPresented: Binding(get: { attachError != nil },
                                              set: { if !$0 { attachError = nil } })) {
            Button("OK") { attachError = nil }
        } message: {
            Text(attachError ?? "")
        }
        .sheet(isPresented: $showSummary) {
            SummarySheet { try await store.summarizeCurrentRoom() }
        }
        .overlay {
            // アイコンタップのプロフィール(画面中央のポップアップ)
            if let m = profileMember {
                MemberProfilePopup(member: m) { profileMember = nil }
            }
        }
    }

    /// 安全モードの確認待ちの色(オレンジ)
    static let reviewOrange = Color(red: 0xc2 / 255.0, green: 0x6a / 255.0, blue: 0x00 / 255.0)

    /// 安全モード: 確認待ちのAI回答の下に出す確認バー(財務のみ)。
    /// 「このまま送信」または「修正して送信」で初めて質問者に表示される
    private func pendingReviewBar(_ msg: Message) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("確認待ち: 質問者にはまだ表示されていません")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Self.reviewOrange)
            HStack(spacing: 8) {
                Button {
                    reviewingMessage = msg
                } label: {
                    Text("修正して送信")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accentDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(.systemBackground)))
                        .overlay(Capsule().stroke(Theme.accentDark, lineWidth: 1))
                }
                Button {
                    store.approvePendingMessage(msg)
                } label: {
                    Text("このまま送信")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
    }

    /// ヘッダー1段: 左にタイトル、右に担当・リンク・要約・完了
    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 14) {
            Text(room?.title ?? "相談")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if store.isExpert, let r = room, store.pendingRoom?.id != r.id {
                // 相談の担当BA(一覧と同じロジック: rooms.handler、未反映の間は案件から補完)。
                // メニューから自分が担当する/他のBAに対応を依頼/担当を外す、ができる
                let handler = r.handler.isEmpty ? store.derivedHandler(roomId: r.id) : r.handler
                Menu {
                    if handler != store.myName() {
                        Button {
                            store.assignRoomHandler(r.id, to: store.myName())
                        } label: {
                            Label("自分が担当する", systemImage: "person.fill.checkmark")
                        }
                    }
                    // 「対応を依頼する」→ 検索できる選択シートを開く(相手の承諾で担当が決まる)
                    Button {
                        showDelegatePicker = true
                    } label: {
                        Label("対応を依頼する", systemImage: "arrowshape.turn.up.right")
                    }
                    if !r.pendingHandler.isEmpty {
                        Button(role: .destructive) {
                            store.cancelHandlerRequest(r.id)
                        } label: {
                            Label("\(r.pendingHandler)さんへの依頼を取り消す", systemImage: "arrow.uturn.backward")
                        }
                    }
                    if !handler.isEmpty {
                        Button(role: .destructive) {
                            store.assignRoomHandler(r.id, to: "")
                        } label: {
                            Label("担当を外す", systemImage: "person.fill.xmark")
                        }
                    }
                } label: {
                    Text(!r.pendingHandler.isEmpty
                         ? "承諾待ち: \(r.pendingHandler)"
                         : (handler.isEmpty ? "担当" : "担当: \(handler)"))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                        .foregroundColor(Color(.darkGray))
                }
                // ラベルの文字数が変わってもMenuが幅を再計算せず一瞬崩れるため、担当名が変わったら作り直す
                .id("handler-\(handler)-\(r.pendingHandler)")
            }
            if store.isExpert, let r = room {
                // この相談へのリンクをコピー(BAチャットに貼るとリンクカードになる)
                Button {
                    UIPasteboard.general.string = "chatbotwest://room/\(r.id)"
                    linkCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        linkCopied = false
                    }
                } label: {
                    Image(systemName: linkCopied ? "checkmark" : "link")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(.darkGray))
                }
            }
            if !store.roomMessages.isEmpty {
                Button("要約") {
                    showSummary = true
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(.darkGray))
            }
            if canToggleDone {
                Button {
                    if let id = store.currentRoomId { store.toggleRoomDone(id) }
                } label: {
                    Text(room?.isDone == true ? "✓ 完了" : "完了")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(room?.isDone == true ? Theme.accent : Color(.systemBackground))
                        .foregroundColor(room?.isDone == true ? .white : Color(.darkGray))
                        .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // ヘッダーもチャット本体と同じ背景色にする
        .background(Theme.chatBg)
        .sheet(isPresented: $showDelegatePicker) {
            if let r = room {
                DelegatePickerSheet(excludeNames: [store.myName(), r.handler, r.pendingHandler]) { name in
                    store.requestRoomHandler(r.id, to: name)
                }
            }
        }
    }

    /// 最下部へスクロールする。吹き出しの高さが出揃うまで位置がずれるので、時間差で数回合わせる
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        for delay in [0.05, 0.35, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if lastMessageId != nil { proxy.scrollTo("roomBottom", anchor: .bottom) }
            }
        }
    }

    /// 自分宛の対応依頼の承諾/辞退バナー
    private func handlerRequestBanner(_ r: Room) -> some View {
        HStack(spacing: 10) {
            Text("\(r.pendingHandlerBy)さんから対応依頼が届いています")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Button("辞退") {
                store.declineHandlerRequest(r.id)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Color(.darkGray))
            Button {
                store.acceptHandlerRequest(r.id)
            } label: {
                Text("承諾")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.12))
    }
}

/// 対応を依頼するBAを検索して選ぶシート
struct DelegatePickerSheet: View {
    @EnvironmentObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    let excludeNames: [String]
    let onPick: (String) -> Void
    @State private var searchText = ""
    @State private var filter = MemberFilter()

    private var pool: [CloudStore.MemberInfo] {
        store.members
            .filter { $0.role == MemberRole.expert.rawValue && !$0.name.isEmpty && !excludeNames.contains($0.name) }
    }

    private var candidates: [CloudStore.MemberInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return pool
            .filter {
                filter.matches($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
                    || $0.affiliation.localizedCaseInsensitiveContains(q))
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MemberFilterBar(filter: $filter, pool: pool)
                List(candidates) { m in
                    Button {
                        onPick(m.name)
                        dismiss()
                    } label: {
                        MemberRow(member: m, isMe: false)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            .navigationTitle("対応を依頼する相手")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "名前・所属で検索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 要約シート

struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let summarize: () async throws -> String
    @State private var summary = ""
    @State private var busy = true
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if busy {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("要約を作成中…").font(.footnote).foregroundColor(.secondary)
                    }
                } else if let errorMessage {
                    Text("⚠ \(errorMessage)")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding()
                } else {
                    ScrollView {
                        Text(summary)
                            .font(.system(size: 14))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("これまでのやり取りの要約")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !busy, errorMessage == nil {
                        Button {
                            UIPasteboard.general.string = summary
                            withAnimation { copied = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                withAnimation { copied = false }
                            }
                        } label: {
                            if copied {
                                Label("コピーしました", systemImage: "checkmark")
                                    .foregroundColor(Theme.accentDark)
                            } else {
                                Label("コピー", systemImage: "doc.on.doc")
                            }
                        }
                        .disabled(copied)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                do {
                    summary = try await summarize()
                } catch {
                    errorMessage = error.localizedDescription
                }
                busy = false
            }
        }
    }
}

// MARK: - メッセージ編集シート

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialText: String
    var title = "メッセージを編集"
    var saveLabel = "保存"
    let onSave: (String) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
            }
            .padding(14)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveLabel) {
                        onSave(text)
                        dismiss()
                    }
                    .bold()
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = initialText }
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
    var avatarIconData: String = ""
    var avatarIcon: String = ""
    var avatarFallback: String = "person.fill"
    var onAvatarTap: (() -> Void)? = nil
    var readStatus: String? = nil
    var myUid: String = ""
    var reactionMemberFor: (String) -> CloudStore.MemberInfo? = { _ in nil }
    var onReaction: (String) -> Void = { _ in }
    let showClarify: Bool
    var onChoice: (String) -> Void = { _ in }
    /// 長押しメニュー(バブル本体に付けるので、プレビューは画面のバブルがそのまま使われる)
    var menuContent: (() -> AnyView)? = nil

    var body: some View {
        if message.role == .system {
            SystemBubble(text: message.text)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if alignRight { Spacer(minLength: 60) }
                if !alignRight {
                    // 相手側はアイコン付きで表示(タップでプロフィール)
                    AvatarCircleView(iconData: avatarIconData, icon: avatarIcon,
                                     fallbackSystemImage: avatarFallback, size: 34)
                        .onTapGesture { onAvatarTap?() }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                VStack(alignment: alignRight ? .trailing : .leading, spacing: 3) {
                    if let senderLabel {
                        Text(senderLabel)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.header.opacity(0.8))
                    }
                    bubbleText
                        .background(LineBubbleShape(isMine: alignRight).fill(bubbleColor))
                        .overlay(
                            LineBubbleShape(isMine: alignRight)
                                .stroke(borderColor ?? .clear, lineWidth: 1)
                        )
                        // 長押しメニューはバブル本体に付ける(プレビュー=画面のバブルそのまま)
                        .contextMenu {
                            if let menuContent {
                                menuContent()
                            }
                        }
                        // 既読・時刻はバブルの下端の真横に固定(リアクションの幅に影響されない)。
                        // 幅0のフレームからバブルの外側へあふれさせる(位置はリアクションの有無で変えない)
                        .overlay(alignment: alignRight ? .bottomLeading : .bottomTrailing) {
                            sideMeta
                                .padding(alignRight ? .trailing : .leading, 4)
                                .padding(.bottom, 6) // バブルの下枠から6pt上
                                .fixedSize()
                                .frame(width: 0, alignment: alignRight ? .trailing : .leading)
                        }
                    if showClarify {
                        // 聞き返しの選択肢ボタン
                        FlowChoices(options: message.clarifyOptions, onChoice: onChoice)
                    }
                    // リアクションはバブルの枠に重ねて表示(バッジの上半分がバブルに掛かる)
                    if !message.reactions.isEmpty, !message.deleted {
                        ReactionChipsView(reactions: message.reactions, myUid: myUid,
                                          memberFor: reactionMemberFor, onToggle: onReaction)
                            .padding(.top, -7) // 間隔3pt込みで枠に4pt重なる
                            .zIndex(1)
                    }
                }
                if !alignRight { Spacer(minLength: 60) }
            }
        }
    }

    /// バブルの横に置く既読・時刻(下揃え・2段)
    private var sideMeta: some View {
        VStack(alignment: alignRight ? .trailing : .leading, spacing: 1) {
            readStatusText
            timeText
        }
        .fixedSize()
    }

    @ViewBuilder
    private var readStatusText: some View {
        if let readStatus {
            Text(readStatus)
                .font(.system(size: 10))
                .foregroundColor(Theme.header.opacity(0.6)) // 時刻と同じ色
        }
    }

    private var bubbleText: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty || message.attachmentType == nil {
                Text(message.text)
                    .font(.system(size: 14))
                    .italic(message.deleted)
                    .foregroundColor(message.deleted ? .secondary : .primary)
                    .lineSpacing(4)
            }
            if !message.deleted, let type = message.attachmentType, let data = message.attachmentData {
                AttachmentContentView(type: type, name: message.attachmentName ?? "", dataB64: data)
            }
        }
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
    var label = "AIアシスタント"
    var alignRight = false

    var body: some View {
        HStack {
            if alignRight { Spacer(minLength: 60) }
            VStack(alignment: alignRight ? .trailing : .leading, spacing: 3) {
                Text(label)
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
            if !alignRight { Spacer(minLength: 60) }
        }
    }
}
