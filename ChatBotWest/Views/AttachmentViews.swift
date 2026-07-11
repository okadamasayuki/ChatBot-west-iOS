import SwiftUI
import UIKit

/// 添付ユーティリティ(圧縮・サイズ上限)
enum AttachmentUtils {
    /// Firestoreの1MB制限に収まる上限(base64膨張を考慮)
    static let maxBytes = 600_000

    /// 画像を上限サイズ以内のJPEGに圧縮する(長辺1280pxに縮小してから品質を段階調整)
    static func compressImage(_ data: Data) -> Data? {
        guard var image = UIImage(data: data) else { return nil }
        let maxDim: CGFloat = 1280
        let longSide = max(image.size.width, image.size.height)
        if longSide > maxDim {
            let scale = maxDim / longSide
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        var quality: CGFloat = 0.7
        var out = image.jpegData(compressionQuality: quality)
        while let d = out, d.count > maxBytes, quality > 0.2 {
            quality -= 0.15
            out = image.jpegData(compressionQuality: quality)
        }
        if let d = out, d.count <= maxBytes { return d }
        return nil
    }
}

/// メッセージ内の添付表示(画像=サムネイル・タップで拡大 / ファイル=カード・タップで共有)
struct AttachmentContentView: View {
    let type: String
    let name: String
    let dataB64: String
    @State private var showImage = false
    @State private var shareURL: URL?

    var body: some View {
        if type == "image", let data = Data(base64Encoded: dataB64), let ui = UIImage(data: data) {
            Button {
                showImage = true
            } label: {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 240)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showImage) {
                ImageViewerSheet(image: ui)
            }
        } else {
            Button {
                openFile()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.tagWaitingFg)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name.isEmpty ? "ファイル" : name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.tagWaitingFg)
                            .lineLimit(1)
                        Text("タップして開く")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Theme.tagWaitingBg)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .sheet(item: $shareURL) { url in
                ActivityView(items: [url])
            }
        }
    }

    private func openFile() {
        guard let data = Data(base64Encoded: dataB64) else { return }
        let fileName = name.isEmpty ? "file" : name
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            print("添付の書き出しに失敗: \(error)")
        }
    }
}

// MARK: - アバター

/// メンバーのアイコン表示(画像 > 絵文字 > フォールバックのSFシンボル)
struct AvatarCircleView: View {
    var iconData: String = ""
    var icon: String = ""
    var fallbackSystemImage = "person.fill"
    var fallbackBg: Color = Theme.chatBg
    var size: CGFloat = 34

    var body: some View {
        Group {
            if !iconData.isEmpty, let data = Data(base64Encoded: iconData), let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else if !icon.isEmpty {
                ZStack {
                    Circle().fill(Color(.systemGray6))
                    Text(icon).font(.system(size: size * 0.55))
                }
            } else {
                ZStack {
                    Circle().fill(fallbackBg)
                    Image(systemName: fallbackSystemImage)
                        .font(.system(size: size * 0.45))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

enum AvatarRenderer {
    /// 絵文字+グラデーション背景のアイコン画像を描画する(AI生成アイコン用)
    static func render(emoji: String, topHex: String, bottomHex: String, size: CGFloat = 256) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { ctx in
            let colors = [uiColor(topHex).cgColor, uiColor(bottomHex).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient,
                                                 start: CGPoint(x: size / 2, y: 0),
                                                 end: CGPoint(x: size / 2, y: size),
                                                 options: [])
            }
            let font = UIFont.systemFont(ofSize: size * 0.55)
            let str = NSAttributedString(string: emoji, attributes: [.font: font])
            let textSize = str.size()
            str.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
        }
    }

    static func uiColor(_ hex: String) -> UIColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return .systemGray4 }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0,
                       alpha: 1)
    }
}

/// メッセージのリアクション表示(絵文字+人数のチップ。タップでトグル)
struct ReactionChipsView: View {
    let reactions: [String: [String]]
    let myUid: String
    /// uid → メンバー情報(長押しの詳細シートでアバター・名前を出すのに使う)
    var memberFor: (String) -> CloudStore.MemberInfo? = { _ in nil }
    let onToggle: (String) -> Void
    @State private var showDetail = false

    var body: some View {
        let items = reactions.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.key) { emoji, uids in
                    // Teams風: 白いピル型バッジ(自分が付けたものは青系ハイライト)。
                    // Teamsと同じく、タップで「誰が押したか」の詳細シートを開く
                    // (長押しはメッセージのメニューと競合するため使わない。付け外しは長押しメニューから)
                    Text("\(emoji) \(uids.count)")
                        .font(.system(size: 12, weight: uids.contains(myUid) ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundColor(uids.contains(myUid) ? Theme.tagWaitingFg : Theme.header)
                        .background(uids.contains(myUid) ? Theme.tagWaitingBg : Color.white)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(uids.contains(myUid) ? Theme.tagWaitingFg.opacity(0.5)
                                             : Color(.separator), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .contentShape(Capsule())
                        .onTapGesture { showDetail = true }
                }
            }
            .sheet(isPresented: $showDetail) {
                ReactionDetailSheet(reactions: reactions, memberFor: memberFor)
            }
        }
    }
}

/// Teams風のリアクション詳細: 上部に絵文字タブ、下に押した人の一覧(アバター+名前+絵文字)
struct ReactionDetailSheet: View {
    let reactions: [String: [String]]
    let memberFor: (String) -> CloudStore.MemberInfo?
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "" // 空 = すべて

    private var items: [(String, [String])] {
        reactions.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
    }

    private var rows: [(id: String, uid: String, emoji: String)] {
        items.flatMap { emoji, uids in
            uids.map { (id: "\(emoji)-\($0)", uid: $0, emoji: emoji) }
        }
        .filter { selected.isEmpty || $0.emoji == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 絵文字タブ(すべて / 絵文字ごと)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tabChip("すべて \(items.reduce(0) { $0 + $1.1.count })", "")
                    ForEach(items, id: \.0) { emoji, uids in
                        tabChip("\(emoji) \(uids.count)", emoji)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Divider()
            List(rows, id: \.id) { row in
                let m = memberFor(row.uid)
                HStack(spacing: 10) {
                    AvatarCircleView(iconData: m?.iconData ?? "", icon: m?.icon ?? "", size: 32)
                    Text(m?.name.isEmpty == false ? m!.name : "不明なユーザ")
                        .font(.system(size: 14))
                    Spacer()
                    Text(row.emoji)
                        .font(.system(size: 18))
                }
            }
            .listStyle(.plain)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func tabChip(_ label: String, _ value: String) -> some View {
        Button {
            selected = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: selected == value ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected == value ? Theme.tagWaitingBg : Color(.secondarySystemBackground))
                .foregroundColor(selected == value ? Theme.tagWaitingFg : .primary)
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
}

/// 画像の拡大表示
struct ImageViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
    }
}
