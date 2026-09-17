import SwiftUI

/// The small amount of state needed to present one activity below the island
/// header. Keeping this value type free of stores and controllers makes the
/// strip useful to any parent that already owns the activity state.
struct IslandActivity: Equatable {
    enum Kind: String, Equatable {
        case power
        case network
        case capsLock
        case volume
        case file
        case focus
        case usage
    }

    let title: String
    let detail: String
    let symbol: String
    let kind: Kind
    let level: Double?

    init(
        title: String,
        detail: String,
        symbol: String,
        kind: Kind,
        level: Double? = nil
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.kind = kind
        self.level = level
    }
}

/// A single compact activity row intended to sit directly below the hardware
/// notch header. The parent supplies the surrounding geometry and background.
struct IslandActivityStrip: View {
    let activity: IslandActivity

    init(activity: IslandActivity) {
        self.activity = activity
    }

    private var accent: Color {
        switch activity.kind {
        case .power:
            return .green
        case .network:
            return .cyan
        case .capsLock:
            return .orange
        case .volume:
            return .blue
        case .file:
            return .purple
        case .focus:
            return .mint
        case .usage:
            return .pink
        }
    }

    private var clampedLevel: Double? {
        guard let level = activity.level, level.isFinite else { return nil }
        return min(max(level, 0), 1)
    }

    private var combinedAccessibilityLabel: String {
        var parts = [activity.title]
        if !activity.detail.isEmpty {
            parts.append(activity.detail)
        }
        if let level = clampedLevel {
            parts.append(String(Int((level * 100).rounded())) + " percent")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: activity.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.18), in: Circle())
                .overlay {
                    Circle()
                        .stroke(accent.opacity(0.3), lineWidth: 0.7)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let level = clampedLevel {
                IslandActivityLevelRail(level: level, tint: accent)
                    .frame(width: 58)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(combinedAccessibilityLabel))
    }
}

private struct IslandActivityLevelRail: View {
    let level: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let height: CGFloat = 4
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))

                Capsule()
                    .fill(tint)
                    .frame(width: width * level)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
