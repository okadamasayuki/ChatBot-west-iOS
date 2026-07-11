import SwiftUI

/// 通知タブ: 担当中の相談への返答・BAトークの新着を貯めて表示する。
/// タップで該当の相談/トークを開く
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
                    Button {
                        store.openNotification(n)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: n.kind == "room" ? "bubble.left.and.bubble.right.fill" : "person.2.fill")
                                .font(.system(size: 16))
                                .foregroundColor(n.read ? Color(.systemGray3) : Theme.accentDark)
                                .frame(width: 26)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.title)
                                    .font(.system(size: 13, weight: n.read ? .regular : .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(n.body)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                Text("\(fmtDate(n.ts)) \(fmtTime(n.ts))")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(.tertiaryLabel))
                            }
                            Spacer()
                            if !n.read {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 6)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteNotification(n.id)
                        } label: {
                            Label("削除", systemImage: "trash.fill")
                        }
                    }
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
}
