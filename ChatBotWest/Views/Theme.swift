import SwiftUI

/// Web版のLINE風配色
/// LINE風の吹き出し(角丸+上端のしっぽ)。isMine=true で右上、false で左上にしっぽ
struct LineBubbleShape: Shape {
    var isMine: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        var p = Path(roundedRect: rect, cornerRadius: r)
        var tail = Path()
        if isMine {
            tail.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            tail.addQuadCurve(to: CGPoint(x: rect.maxX + 7, y: rect.minY - 1),
                              control: CGPoint(x: rect.maxX + 1, y: rect.minY - 2))
            tail.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                              control: CGPoint(x: rect.maxX, y: rect.minY + 3))
        } else {
            tail.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            tail.addQuadCurve(to: CGPoint(x: rect.minX - 7, y: rect.minY - 1),
                              control: CGPoint(x: rect.minX - 1, y: rect.minY - 2))
            tail.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r),
                              control: CGPoint(x: rect.minX, y: rect.minY + 3))
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
