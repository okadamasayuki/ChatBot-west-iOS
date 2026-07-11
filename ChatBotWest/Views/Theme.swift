import SwiftUI

/// Web版のLINE風配色
/// 吹き出し(角丸+下角の小さなしっぽ)。isMine=true で右下、false で左下にしっぽ
struct LineBubbleShape: Shape {
    var isMine: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        var p = Path(roundedRect: rect, cornerRadius: r)
        var tail = Path()
        if isMine {
            // 右下の角から小さな三角が出る
            tail.move(to: CGPoint(x: rect.maxX - r - 4, y: rect.maxY - 1))
            tail.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY + 6))
            tail.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY - r + 2))
        } else {
            // 左下の角から小さな三角が出る
            tail.move(to: CGPoint(x: rect.minX + r + 4, y: rect.maxY - 1))
            tail.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY + 6))
            tail.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY - r + 2))
        }
        tail.closeSubpath()
        p.addPath(tail)
        return p
    }
}

enum Theme {
    static let header = Color(red: 0x27 / 255, green: 0x32 / 255, blue: 0x46 / 255)      // #273246
    static let chatBg = Color(red: 0x8c / 255, green: 0xab / 255, blue: 0xd8 / 255)      // #8cabd8
    static let accent = Color(red: 0x06 / 255, green: 0xc7 / 255, blue: 0x55 / 255)      // #06c755
    static let accentDark = Color(red: 0x06 / 255, green: 0x86 / 255, blue: 0x4a / 255)  // #06864a
    static let myBubble = Color(red: 0x8d / 255, green: 0xe0 / 255, blue: 0x55 / 255)    // #8de055
    static let expertBubble = Color(red: 1.0, green: 0xf8 / 255.0, blue: 0xdc / 255.0)   // #fff8dc
    static let expertBorder = Color(red: 0xe8 / 255, green: 0xd4 / 255, blue: 0x8a / 255) // #e8d48a
    static let panelBg = Color(red: 0xee / 255, green: 0xf1 / 255, blue: 0xf6 / 255)     // #eef1f6
    static let tagPendingBg = Color(red: 1.0, green: 0xf2 / 255.0, blue: 0xcc / 255.0)   // #fff2cc
    static let tagPendingFg = Color(red: 0x8a / 255, green: 0x6d / 255, blue: 0x00 / 255)
    static let tagDoneBg = Color(red: 0xe3 / 255, green: 0xf6 / 255, blue: 0xe9 / 255)
    static let tagDoneFg = Color(red: 0x1f / 255, green: 0x8a / 255, blue: 0x4c / 255)
    static let tagWaitingBg = Color(red: 0xe7 / 255, green: 0xf0 / 255, blue: 1.0)       // #e7f0ff
    static let tagWaitingFg = Color(red: 0x2a / 255, green: 0x6f / 255, blue: 0xd6 / 255) // #2a6fd6
}
