import SwiftUI

/// Web版のLINE風配色
/// LINEの吹き出しと同じ形(強い丸み+上角の跳ねたしっぽ)を1つの連続パスで描く。
/// isMine=true で右上、false で左上にしっぽ
struct LineBubbleShape: Shape {
    var isMine: Bool

    func path(in rect: CGRect) -> Path {
        let r = min(20, rect.height / 2)          // 角の丸み(1行ならカプセルに近い)
        let drop = min(16, rect.height * 0.55)    // しっぽが辺に合流する位置
        var p = Path()
        if isMine {
            p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.minY))
            // 右上のしっぽ: 外へ跳ねて右辺に合流
            p.addQuadCurve(to: CGPoint(x: rect.maxX + 9, y: rect.minY - 5),
                           control: CGPoint(x: rect.maxX + 1, y: rect.minY - 1))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + drop),
                           control: CGPoint(x: rect.maxX, y: rect.minY + 2))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                           control: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + 6, y: rect.minY))
            // 左上のしっぽ: 外へ跳ねて左辺に合流
            p.addQuadCurve(to: CGPoint(x: rect.minX - 9, y: rect.minY - 5),
                           control: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + drop),
                           control: CGPoint(x: rect.minX, y: rect.minY + 2))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.closeSubpath()
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
