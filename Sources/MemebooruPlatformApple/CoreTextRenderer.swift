#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import MemebooruCore

/// Tweet text through CoreText: system font, word wrap, colour emoji, "…" on the last allowed line.
public struct CoreTextRenderer: TextRenderer {
    public init() {}

    public func render(_ text: String, style: TextStyle, width: Int) throws -> Bitmap? {
        guard !text.isEmpty, width > 0,
              let font = CTFontCreateUIFontForLanguage(style.bold ? .emphasizedSystem : .system, CGFloat(style.size), nil)
        else { return nil }
        let color = CGColor(srgbRed: CGFloat(style.color >> 16 & 0xFF) / 255, green: CGFloat(style.color >> 8 & 0xFF) / 255,
                            blue: CGFloat(style.color & 0xFF) / 255, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        var lines: [CTLine] = []
        var start = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            if style.maxLines > 0, lines.count == style.maxLines - 1, start + count < length {
                // Last allowed line: the rest of the text, cut with an ellipsis.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? rest)
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        guard !lines.isEmpty else { return nil }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent + CTFontGetLeading(font)) * 1.08
        let widest = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0) }.max() ?? 0
        let w = max(1, min(width, Int(widest.rounded(.up)) + 1))
        let h = max(1, Int((lineHeight * CGFloat(lines.count)).rounded(.up)))
        var data = Data(count: w * h * 4)
        try data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw PlatformAppleError(description: "CGContext failed") }
            ctx.setShouldSmoothFonts(false)
            ctx.textMatrix = .identity
            for (i, line) in lines.enumerated() {
                ctx.textPosition = CGPoint(x: 0, y: CGFloat(h) - CGFloat(i) * lineHeight - ascent)
                CTLineDraw(line, ctx)
            }
            // Bitmap is straight alpha.
            let p = buf.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) {
                let a = Int(p[i + 3])
                guard a > 0, a < 255 else { continue }
                for k in 0..<3 { p[i + k] = UInt8(min(255, (Int(p[i + k]) * 255 + a / 2) / a)) }
            }
        }
        return Bitmap(width: w, height: h, rgba: data)
    }
}
#endif
