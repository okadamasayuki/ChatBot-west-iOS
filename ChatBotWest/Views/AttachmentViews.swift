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
    let onToggle: (String) -> Void

    var body: some View {
        let items = reactions.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.key) { emoji, uids in
                    Button {
                        onToggle(emoji)
                    } label: {
                        // 背景なしの透明表示(絵文字と数だけ)。自分が付けたものは枠線+うっすら白背景で分かるようにする
                        Text("\(emoji) \(uids.count)")
                            .font(.system(size: 12, weight: uids.contains(myUid) ? .semibold : .regular))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .foregroundColor(Theme.header.opacity(uids.contains(myUid) ? 1.0 : 0.7))
                            .background(Color.white.opacity(uids.contains(myUid) ? 0.25 : 0))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(Theme.header.opacity(uids.contains(myUid) ? 0.6 : 0), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
