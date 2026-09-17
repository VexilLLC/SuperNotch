import SwiftUI
import AppKit

// Shared building blocks for the Activity destination (Performance, Battery,
// Network, Volumes and Events). Everything here is dark-surface only, matches
// the workspace chrome, and avoids per-frame work: charts use native Core Graphics
// draws and nothing animates unless a value changes.

enum ActivityMetrics {
    static let spacing: CGFloat = 14
    static let cardRadius: CGFloat = 18
    static let historyCapacity = 60
}

extension View {
    /// The standard Activity surface: a quiet glass panel with a hairline
    /// highlight and an optional accent wash in the top-leading corner.
    func activityCard(padding: CGFloat = 18, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: ActivityMetrics.cardRadius, style: .continuous)
                ZStack {
                    shape.fill(Color.white.opacity(0.042))
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0)], startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 0.8)))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: ActivityMetrics.cardRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.045)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            }
    }

    /// Measures the width this view is offered and reports it through a
    /// binding. The value only changes when the width really changes, so it is
    /// safe to drive column counts without layout feedback loops.
    func activityWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width.rounded()
        } action: { newValue in
            if abs(width.wrappedValue - newValue) >= 1 { width.wrappedValue = newValue }
        }
    }
}

/// Small tinted symbol square used in card headers.
struct ActivityIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ActivityCardHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ActivityIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension ActivityCardHeader where Trailing == EmptyView {
    init(title: String, symbol: String, tint: Color, subtitle: String? = nil) {
        self.init(title: title, symbol: symbol, tint: tint, subtitle: subtitle) { EmptyView() }
    }
}

/// A capsule label with a status dot.
struct ActivityPill: View {
    let text: String
    var color: Color = .green
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.6))
        .fixedSize()
    }
}

/// A circular progress ring with a centered value.
struct ActivityRing: View {
    let fraction: Double
    let tint: Color
    let value: String
    var caption: String?
    var lineWidth: CGFloat = 9

    var body: some View {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        ZStack {
            NativeActivityRing(fraction: clamped, tint: tint, lineWidth: lineWidth)
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let caption {
                    Text(caption).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            .padding(lineWidth + 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "Usage")
        .accessibilityValue(value)
    }
}

/// A horizontal capsule meter made of one or more stacked segments.
struct ActivityBar: View {
    struct Segment: Identifiable {
        let fraction: Double
        let color: Color
        var id: Int
    }

    let segments: [Segment]
    var height: CGFloat = 8

    init(fraction: Double, color: Color, height: CGFloat = 8) {
        self.segments = [Segment(fraction: fraction, color: color, id: 0)]
        self.height = height
    }

    init(segments: [(Double, Color)], height: CGFloat = 8) {
        self.segments = segments.enumerated().map { Segment(fraction: $0.element.0, color: $0.element.1, id: $0.offset) }
        self.height = height
    }

    var body: some View {
        NativeActivityBar(segments: segments)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Dot, label and a value that never truncates before the label does.
struct ActivityLegendRow: View {
    let label: String
    let value: String
    var color: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color ?? .secondary).frame(width: 12)
            } else if let color {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rolling time-series chart. Samples are right-aligned into a fixed number
/// of slots, so a fresh chart visibly fills in from the right instead of
/// stretching a couple of points across the whole width.
struct ActivityChart: View {
    struct Series {
        let values: [Double]
        let color: Color
        var filled = true
    }

    let series: [Series]
    var capacity = ActivityMetrics.historyCapacity
    /// A fixed upper bound (for percentages). When nil the chart scales to its data.
    var maximum: Double?
    var minimumScale: Double = 1
    var gridLines = 3
    var showsGrid = true
    var lineWidth: CGFloat = 1.7
    var showsEndDot = true

    var body: some View {
        NativeActivityChart(chart: self)
            .accessibilityHidden(true)
    }

    /// The upper bound currently used for drawing; exposed so callers can label the scale.
    var resolvedMaximum: Double {
        if let maximum { return maximum }
        let peak = series.flatMap { $0.values.suffix(capacity) }.filter(\.isFinite).max() ?? 0
        return ActivityFormat.niceCeiling(max(minimumScale, peak * 1.1))
    }

    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            if index == 1 {
                path.addLine(to: mid)
            } else {
                path.addQuadCurve(to: mid, control: previous)
            }
            if index == points.count - 1 { path.addLine(to: current) }
        }
        return path
    }
}

/// A compact KPI tile with a value, supporting detail and optional sparkline.
struct ActivityTile<Footer: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var detail: String
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ActivityIcon(symbol: symbol, tint: tint, size: 24)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 12)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .padding(.top, 2)
            Spacer(minLength: 10)
            footer
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .activityCard(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

extension ActivityTile where Footer == EmptyView {
    init(title: String, symbol: String, tint: Color, value: String, detail: String) {
        self.init(title: title, symbol: symbol, tint: tint, value: value, detail: detail) { EmptyView() }
    }
}

/// A calm placeholder for sections that are still waiting on a first reading.
struct ActivityPlaceholder: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.white.opacity(0.4))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// A round icon button matching the workspace header buttons.
struct ActivityIconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.07), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.7))
        }
        .buttonStyle(IslandPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

enum ActivityFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    static func memory(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite else { return "—" }
        let value = max(0, bytesPerSecond)
        if value < 1_000 { return "\(Int(value.rounded())) B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// Rounds a positive value up to 1, 2 or 5 times a power of ten.
    static func niceCeiling(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for multiplier in [1.0, 2.0, 5.0, 10.0] where value <= multiplier * base {
            return multiplier * base
        }
        return 10 * base
    }
}
