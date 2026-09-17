import SwiftUI
import AppKit

/// Animated audio level bars rendered with Core Animation.
///
/// The animation runs in the render server, so an always-visible indicator (the collapsed island,
/// the workspace sidebar) costs no SwiftUI graph updates or layout passes per frame.
struct LevelBars: NSViewRepresentable {
    var playing: Bool
    var color: Color
    var count = 4
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 13

    func makeNSView(context: Context) -> LevelBarsView { LevelBarsView() }

    func updateNSView(_ view: LevelBarsView, context: Context) {
        view.configure(count: count, barWidth: barWidth, spacing: spacing, maxHeight: maxHeight, color: NSColor(color), playing: playing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LevelBarsView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(count) * barWidth + CGFloat(max(0, count - 1)) * spacing, height: maxHeight)
    }
}

final class LevelBarsView: NSView {
    private var bars: [CALayer] = []
    private var signature = ""
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var isFlipped: Bool { true }

    func configure(count: Int, barWidth: CGFloat, spacing: CGFloat, maxHeight: CGFloat, color: NSColor, playing: Bool) {
        let newSignature = "\(count)|\(barWidth)|\(spacing)|\(maxHeight)|\(color)"
        if newSignature != signature {
            signature = newSignature
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<count).map { index in
                let bar = CALayer()
                bar.backgroundColor = color.cgColor
                bar.cornerRadius = barWidth / 2
                bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barWidth + 1)
                bar.position = CGPoint(x: CGFloat(index) * (barWidth + spacing) + barWidth / 2, y: maxHeight / 2)
                layer?.addSublayer(bar)
                return bar
            }
            animating = false
        }
        guard playing != animating else { return }
        animating = playing
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            guard playing else { continue }
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = maxHeight * 0.3
            animation.toValue = maxHeight
            animation.duration = [0.42, 0.31, 0.5, 0.37, 0.45][index % 5]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.timeOffset = Double(index) * 0.13
            bar.add(animation, forKey: "level")
        }
    }
}
