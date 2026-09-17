import AppKit
import SwiftUI

/// Core Graphics charts avoid a persistent Metal render-resource pool. Used
/// by both the always-visible menu bar and the larger Activity dashboards.
struct NativeActivityChart: NSViewRepresentable {
    let chart: ActivityChart

    func makeNSView(context: Context) -> ActivityChartDrawingView { ActivityChartDrawingView() }

    func updateNSView(_ view: ActivityChartDrawingView, context: Context) {
        view.chart = chart
        view.needsDisplay = true
    }
}

final class ActivityChartDrawingView: NSView {
    var chart = ActivityChart(series: [])
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let upper = chart.resolvedMaximum
        guard upper.isFinite, upper > 0, bounds.width > 0, bounds.height > 2 else { return }
        if chart.showsGrid, chart.gridLines > 0 {
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
            context.setLineWidth(0.7)
            context.setLineDash(phase: 0, lengths: [2, 4])
            for step in 1...chart.gridLines {
                let y = (bounds.height * CGFloat(step) / CGFloat(chart.gridLines + 1)).rounded() + 0.5
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
                context.strokePath()
            }
            context.restoreGState()
        }
        let slots = max(2, chart.capacity)
        let step = bounds.width / CGFloat(slots - 1)
        context.setLineWidth(chart.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for entry in chart.series {
            let values = entry.values.suffix(slots)
            guard values.count > 1 else { continue }
            let offset = slots - values.count
            let points = values.enumerated().map { index, value in
                let safe = value.isFinite ? max(0, value) : 0
                return CGPoint(x: CGFloat(offset + index) * step,
                               y: bounds.height - CGFloat(min(1, safe / upper)) * (bounds.height - 2) - 1)
            }
            let path = ActivityChart.smoothPath(points).cgPath
            let color = NSColor(entry.color)
            if entry.filled, let area = path.mutableCopy() {
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bounds.height))
                area.addLine(to: CGPoint(x: points[0].x, y: bounds.height))
                area.closeSubpath()
                context.saveGState()
                context.addPath(area)
                context.clip()
                let colors = [color.withAlphaComponent(0.32).cgColor, color.withAlphaComponent(0.02).cgColor]
                if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]) {
                    context.drawLinearGradient(gradient, start: .zero,
                                               end: CGPoint(x: 0, y: bounds.height), options: [])
                }
                context.restoreGState()
            }
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.strokePath()
            if chart.showsEndDot, let last = points.last {
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6))
            }
        }
    }
}

struct NativeCoreActivityGrid: NSViewRepresentable {
    let grid: CoreActivityGrid
    func makeNSView(context: Context) -> CoreActivityDrawingView { CoreActivityDrawingView() }
    func updateNSView(_ view: CoreActivityDrawingView, context: Context) {
        view.grid = grid
        view.needsDisplay = true
    }
}

final class CoreActivityDrawingView: NSView {
    var grid = CoreActivityGrid(values: [], layout: nil)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        let labelHeight: CGFloat = 14
        let barHeight = max(8, size.height - labelHeight)
        let groups = grid.groups
        let groupGap: CGFloat = groups.count > 1 ? 14 : 0
        let barGap: CGFloat = 3
        let count = CGFloat(grid.values.count)
        let totalGaps = barGap * max(0, count - CGFloat(groups.count)) + groupGap * CGFloat(max(0, groups.count - 1))
        let barWidth = min(12, max(2, (size.width - totalGaps) / max(1, count)))
        var x = max(0, size.width - barWidth * count - totalGaps)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4)
        ]
        for (groupIndex, group) in groups.enumerated() {
            let startX = x
            for index in group.range {
                let raw = grid.values[index]
                let value = raw.isFinite ? min(100, max(0, raw)) / 100 : 0
                let track = CGRect(x: x, y: 0, width: barWidth, height: barHeight)
                let radius = min(3, barWidth / 2)
                context.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
                context.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
                let height = max(value > 0.005 ? 2 : 0, barHeight * CGFloat(value))
                if height > 0 {
                    let fill = CGRect(x: x, y: barHeight - height, width: barWidth, height: height)
                    context.setFillColor(NSColor(grid.color(value * 100, efficiency: group.efficiency)).cgColor)
                    context.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    context.fillPath()
                }
                x += barWidth + barGap
            }
            x -= barGap
            if let title = group.title {
                var label = NSAttributedString(string: title, attributes: attributes)
                if label.size().width > x - startX + groupGap, let short = group.shortTitle {
                    label = NSAttributedString(string: short, attributes: attributes)
                }
                let labelSize = label.size()
                let midX = min(max((startX + x) / 2, labelSize.width / 2), size.width - labelSize.width / 2)
                label.draw(at: CGPoint(x: midX - labelSize.width / 2,
                                       y: size.height - labelHeight / 2 + 1 - labelSize.height / 2))
            }
            if groupIndex < groups.count - 1 { x += groupGap }
        }
    }
}

struct NativeActivityRing: NSViewRepresentable {
    let fraction: Double
    let tint: Color
    let lineWidth: CGFloat
    func makeNSView(context: Context) -> ActivityRingDrawingView { ActivityRingDrawingView() }
    func updateNSView(_ view: ActivityRingDrawingView, context: Context) {
        view.fraction = fraction
        view.tint = NSColor(tint)
        view.lineWidth = lineWidth
        view.needsDisplay = true
    }
}

final class ActivityRingDrawingView: NSView {
    var fraction = 0.0
    var tint = NSColor.systemBlue
    var lineWidth: CGFloat = 9
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(0, (min(bounds.width, bounds.height) - lineWidth) / 2)
        guard radius > 0 else { return }
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard value > 0 else { return }
        context.setStrokeColor(tint.cgColor)
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: -.pi / 2,
                       endAngle: -.pi / 2 + value * 2 * .pi, clockwise: false)
        context.strokePath()
    }
}

struct NativeActivityBar: NSViewRepresentable {
    let segments: [ActivityBar.Segment]
    func makeNSView(context: Context) -> ActivityBarDrawingView { ActivityBarDrawingView() }
    func updateNSView(_ view: ActivityBarDrawingView, context: Context) {
        view.segments = segments
        view.needsDisplay = true
    }
}

final class ActivityBarDrawingView: NSView {
    var segments: [ActivityBar.Segment] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2,
                              cornerHeight: bounds.height / 2, transform: nil))
        context.clip()
        context.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.fill(bounds)
        var x = bounds.minX
        for segment in segments {
            let fraction = segment.fraction.isFinite ? min(1, max(0, segment.fraction)) : 0
            let width = bounds.width * fraction
            context.setFillColor(NSColor(segment.color).cgColor)
            context.fill(CGRect(x: x, y: bounds.minY, width: width, height: bounds.height))
            x += width
        }
    }
}
