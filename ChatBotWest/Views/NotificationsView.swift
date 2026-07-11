import SwiftUI

/// 通知タブ: 担当中の相談への返答・BAトークの新着・対応依頼のやりとりを貯めて表示する。
/// タップで該当の相談/トークを開く。左スライドで削除(BAチャット一覧と同じモーション)
struct NotificationsView: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        NavigationStack {
            List {
                if store.notifications.isEmpty {
                    Text("通知はまだありません。\n担当中の相談への返答や、BAチャットの新着がここに届きます。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowSeparator(.hidden)
                }
                ForEach(store.notifications) { n in
                    // 左スライド=削除 / 右スライド=未読⇄既読
                    SwipeDeleteRow(onDelete: { store.deleteNotification(n.id) },
                                   leadingIcon: n.read ? "envelope.badge.fill" : "envelope.open.fill",
                                   onLeading: { store.toggleNotificationRead(n.id) },
                                   contentInsets: EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)) {
                        notificationRow(n)
                            .contentShape(Rectangle())
                            .onTapGesture { store.openNotification(n) }
                    }
                    // 区切り線を全行とも左端から表示
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
            .listStyle(.plain)
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("すべて既読") {
                        store.markAllNotificationsRead()
                    }
                    .font(.system(size: 13))
                    .disabled(store.unreadNotificationCount == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func notificationRow(_ n: CloudStore.AppNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.kind == "room" ? "bubble.left.and.bubble.right.fill" : "person.2.fill")
                .font(.system(size: 16))
                .foregroundColor(n.read ? Color(.systemGray3) : Theme.accentDark)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title)
                    .font(.system(size: 13, weight: n.read ? .regular : .semibold))
                    .foregroundColor(n.read ? .primary : Theme.accentDark) // 未読は全部緑
                    .lineLimit(1)
                // どんな対応が必要か
                if let action = n.action, !action.isEmpty {
                    Text(action)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(n.read ? Color(.secondaryLabel) : Theme.accentDark)
                        .lineLimit(2)
                }
                Text(fmtTime(n.ts)) // "M/d H:mm"
                    .font(.system(size: 10))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
