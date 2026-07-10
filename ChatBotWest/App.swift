import SwiftUI
import FirebaseCore

/// Web版 (chatbot-west) と同じ Firebase プロジェクトに接続する。
/// GoogleService-Info.plist がバンドルにあればそれを優先し、
/// なければ Web 版と同じ設定値でプログラム的に初期化する。
enum FirebaseSetup {
    static let workspaceCode = "chatbotwest-5b568-main"

    static func configure() {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            return
        }
        let options = FirebaseOptions(
            googleAppID: "1:36025349912:web:e89a3ad0b8eb1fe4b6d06d",
            gcmSenderID: "36025349912"
        )
        options.apiKey = "AIzaSyBh_8IDFllTnaJlZm3xPMm-TY_mTGWJ7Es"
        options.projectID = "chatbotwest-5b568"
        options.storageBucket = "chatbotwest-5b568.firebasestorage.app"
        FirebaseApp.configure(options: options)
    }
}

@main
struct ChatBotWestApp: App {
    @StateObject private var store: CloudStore

    init() {
        FirebaseSetup.configure()
        _store = StateObject(wrappedValue: CloudStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
