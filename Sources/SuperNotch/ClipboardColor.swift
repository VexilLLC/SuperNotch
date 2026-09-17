import Foundation
import SwiftUI

/// A normalized color value that can safely be derived from clipboard text.
///
/// The parser intentionally accepts only a small, unambiguous subset of CSS
/// color syntax. It is kept independent from the clipboard store so callers
/// can use it for previews without granting the view any clipboard access.
struct ClipboardColorValue: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    /// Creates a normalized value. Non-finite components become zero and
    /// finite components are clamped to the unit interval.
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.normalized(r)
        self.g = Self.normalized(g)
        self.b = Self.normalized(b)
        self.a = Self.normalized(a)
    }

    /// Parses a complete, trimmed color string.
    ///
    /// Supported forms are `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`,
    /// comma-separated `rgb(...)`, and comma-separated `rgba(...)`. RGB
    /// channels may all be numbers in the 0...255 range or all be percentages
    /// in the 0...100% range. Alpha may be a number in the 0...1 range or a
    /// percentage. Mixed numeric and percentage RGB channels are rejected.
    static func parse(_ text: String) -> Self? {
        // Clipboard text can be arbitrary. Keep parsing bounded before doing
        // any trimming, case conversion, or numeric work.
        guard text.utf8.prefix(maxInputUTF8Length + 1).count <= maxInputUTF8Length else { return nil }

        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= maxInputUTF8Length else { return nil }

        if candidate.first == "#" {
            return parseHex(candidate)
        }

        // Function names and numeric tokens are ASCII. Rejecting other scalar
        // values first also keeps case conversion from changing the grammar.
        guard candidate.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
        return parseFunction(candidate)
    }

    /// The shortest canonical uppercase hexadecimal representation. Opaque
    /// colors use six digits; colors with transparency use eight digits.
    var canonicalHex: String {
        let red = Self.byte(for: r)
        let green = Self.byte(for: g)
        let blue = Self.byte(for: b)
        var result = "#" + Self.hexPair(red) + Self.hexPair(green) + Self.hexPair(blue)
        if a < 1 {
            result += Self.hexPair(Self.byte(for: a))
        }
        return result
    }

    /// Display text shared by compact and full clipboard previews.
    var displayLabel: String { canonicalHex }

    /// A concise description suitable for assistive technologies.
    var accessibilityDescription: String {
        let red = Self.byte(for: r)
        let green = Self.byte(for: g)
        let blue = Self.byte(for: b)
        let alpha = Self.byte(for: a)
        return "Color \(canonicalHex), red \(red), green \(green), blue \(blue), alpha \(alpha)"
    }

    private static let maxInputUTF8Length = 256
    private static let hexDigits = Array("0123456789ABCDEF")

    private static func normalized(_ component: Double) -> Double {
        guard component.isFinite else { return 0 }
        return min(max(component, 0), 1)
    }

    private static func byte(for component: Double) -> Int {
        // Parsed values are already normalized, but keeping the clamp here
        // makes formatting safe for values created with the public initializer.
        let normalized = Self.normalized(component)
        return min(max(Int((normalized * 255).rounded()), 0), 255)
    }

    private static func hexPair(_ value: Int) -> String {
        let clamped = min(max(value, 0), 255)
        return String(hexDigits[clamped >> 4]) + String(hexDigits[clamped & 0x0F])
    }

    private static func parseHex(_ candidate: String) -> Self? {
        let digits = Array(candidate.dropFirst().utf8)
        guard [3, 4, 6, 8].contains(digits.count) else { return nil }

        var values: [Int] = []
        values.reserveCapacity(digits.count)
        for digit in digits {
            guard let value = hexValue(digit) else { return nil }
            values.append(value)
        }

        if values.count == 3 || values.count == 4 {
            let red = Double(values[0] * 17) / 255
            let green = Double(values[1] * 17) / 255
            let blue = Double(values[2] * 17) / 255
            let alpha = values.count == 4 ? Double(values[3] * 17) / 255 : 1
            return Self(r: red, g: green, b: blue, a: alpha)
        }

        let red = Double(values[0] * 16 + values[1]) / 255
        let green = Double(values[2] * 16 + values[3]) / 255
        let blue = Double(values[4] * 16 + values[5]) / 255
        let alpha = values.count == 8 ? Double(values[6] * 16 + values[7]) / 255 : 1
        return Self(r: red, g: green, b: blue, a: alpha)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 48...57: return Int(byte - 48)
        case 65...70: return Int(byte - 65) + 10
        case 97...102: return Int(byte - 97) + 10
        default: return nil
        }
    }

    private static func parseFunction(_ candidate: String) -> Self? {
        let lowercased = candidate.lowercased()
        let function: String
        let expectedPartCount: Int
        if lowercased.hasPrefix("rgb(") {
            function = "rgb("
            expectedPartCount = 3
        } else if lowercased.hasPrefix("rgba(") {
            function = "rgba("
            expectedPartCount = 4
        } else {
            return nil
        }

        guard lowercased.hasSuffix(")") else { return nil }
        let bodyStart = candidate.index(candidate.startIndex, offsetBy: function.count)
        let bodyEnd = candidate.index(before: candidate.endIndex)
        guard bodyStart <= bodyEnd else { return nil }

        let body = String(candidate[bodyStart..<bodyEnd])
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == expectedPartCount else { return nil }

        let channels = parts.prefix(3).compactMap(parseRGBChannel)
        guard channels.count == 3 else { return nil }
        guard Set(channels.map(\.isPercentage)).count == 1 else { return nil }

        let alpha: Double
        if expectedPartCount == 4 {
            guard let parsedAlpha = parseAlpha(parts[3]) else { return nil }
            alpha = parsedAlpha
        } else {
            alpha = 1
        }

        return Self(r: channels[0].value, g: channels[1].value, b: channels[2].value, a: alpha)
    }

    private static func parseRGBChannel(_ rawToken: String) -> (value: Double, isPercentage: Bool)? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.last == "%" {
            let number = String(token.dropLast())
            guard let value = parseFiniteDecimal(number), (0...100).contains(value) else { return nil }
            return (value / 100, true)
        }

        guard !token.contains("%"), let value = parseFiniteDecimal(token), (0...255).contains(value) else {
            return nil
        }
        return (value / 255, false)
    }

    private static func parseAlpha(_ rawToken: String) -> Double? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.last == "%" {
            let number = String(token.dropLast())
            guard let value = parseFiniteDecimal(number), (0...100).contains(value) else { return nil }
            return value / 100
        }

        guard !token.contains("%"), let value = parseFiniteDecimal(token), (0...1).contains(value) else {
            return nil
        }
        return value
    }

    private static func parseFiniteDecimal(_ token: String) -> Double? {
        let bytes = Array(token.utf8)
        guard !bytes.isEmpty else { return nil }
        guard bytes.allSatisfy({
            switch $0 {
            case 48...57, 43, 45, 46, 69, 101: return true
            default: return false
            }
        }) else { return nil }
        guard let value = Double(token), value.isFinite else { return nil }
        return value
    }
}

/// A clipboard color preview with an alpha checkerboard and a contrasting
/// hexadecimal label. This view intentionally has no clipboard side effects.
struct ClipboardColorSwatch: View {
    let value: ClipboardColorValue
    var compact: Bool = false

    private var swatchWidth: CGFloat { compact ? 76 : 112 }
    private var swatchHeight: CGFloat { compact ? 56 : 78 }
    private var cornerRadius: CGFloat { compact ? 8 : 10 }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 10) {
            colorWell

            if !compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.displayLabel)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text("R \(Self.byte(for: value.r)) · G \(Self.byte(for: value.g)) · B \(Self.byte(for: value.b))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if value.a < 1 {
                        Text("Alpha \(Self.percent(for: value.a))%")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Color \(value.displayLabel)"))
        .accessibilityValue(Text(value.accessibilityDescription))
    }

    private var colorWell: some View {
        ZStack {
            ClipboardColorCheckerboard(tile: compact ? 7 : 8)
            Color(red: value.r, green: value.g, blue: value.b, opacity: value.a)

            Text(value.displayLabel)
                .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.contrastColor(for: value))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Self.contrastColor(for: value).opacity(0.12), in: Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(width: swatchWidth, height: swatchHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private static func byte(for component: Double) -> Int {
        min(max(Int((min(max(component, 0), 1) * 255).rounded()), 0), 255)
    }

    private static func percent(for component: Double) -> Int {
        min(max(Int((min(max(component, 0), 1) * 100).rounded()), 0), 100)
    }

    private static func contrastColor(for value: ClipboardColorValue) -> Color {
        // Compare against a neutral checkerboard midpoint so translucent
        // swatches retain a readable label over both light and dark tiles.
        let background = 0.5
        let red = value.r * value.a + background * (1 - value.a)
        let green = value.g * value.a + background * (1 - value.a)
        let blue = value.b * value.a + background * (1 - value.a)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.54 ? .black : .white
    }
}

private struct ClipboardColorCheckerboard: View {
    let tile: CGFloat

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Color.white.opacity(0.16)))

            let columns = max(Int(ceil(size.width / tile)), 1)
            let rows = max(Int(ceil(size.height / tile)), 1)
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(Color.black.opacity(0.16)))
                }
            }
        }
        .background(Color.white.opacity(0.08))
    }
}
