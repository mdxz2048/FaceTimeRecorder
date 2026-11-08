import Foundation
import SwiftUI

// MARK: - Card

struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let content: Content

    init(title: String,
         subtitle: String? = nil,
         icon: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Status pill

struct StatusPill: View {
    enum Tone {
        case neutral
        case info
        case success
        case warning
        case danger

        var color: Color {
            switch self {
            case .neutral: return .secondary
            case .info: return .blue
            case .success: return .green
            case .warning: return .orange
            case .danger: return .red
            }
        }

        var symbolName: String {
            switch self {
            case .neutral: return "circle"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            }
        }
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Level meters

/// Displays only values reported by Core (`LiveSnapshot`). No synthesized
/// waveforms and no decay animation are used.
struct LevelMeter: View {
    let title: String
    let rms: Float
    let peak: Float
    var secondaryRMS: Float? = nil
    var secondaryPeak: Float? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(levelText(rms))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            MeterBar(value: rms, peak: peak, channel: secondaryRMS == nil ? nil : "L")
            if let secondaryRMS = secondaryRMS {
                MeterBar(value: secondaryRMS, peak: secondaryPeak ?? 0, channel: "R")
            }
        }
    }

    private func levelText(_ value: Float) -> String {
        guard value > 1e-7 else { return "无信号" }
        let db = 20 * log10(Double(value))
        return String(format: "%.1f dBFS", max(-120, db))
    }
}

private struct MeterBar: View {
    let value: Float
    let peak: Float
    let channel: String?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [.green, .yellow, .orange, .red],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: width * fraction(value))
                if peak > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2)
                        .offset(x: max(0, min(width - 2, width * fraction(peak))))
                }
                if let channel = channel {
                    Text(channel)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.leading, 4)
                }
            }
        }
        .frame(height: 10)
    }

    private func fraction(_ value: Float) -> CGFloat {
        let amplitude = Double(max(0, value))
        guard amplitude > 1e-7 else { return 0 }
        let db = 20 * log10(amplitude)
        let clamped = min(0, max(-60, db))
        return CGFloat((clamped + 60) / 60)
    }
}

// MARK: - Event row

struct EventRow: View {
    let entry: AppLog.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.level.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.level.color)
                .frame(width: 14, height: 14)
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(entry.message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

extension AppLog.Level {
    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

// MARK: - Banner

struct NoticeBanner: View {
    let title: String
    let message: String
    var tone: StatusPill.Tone = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.symbolName)
                .foregroundStyle(tone.color)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tone.color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Small rows

struct PermissionRow: View {
    let title: String
    let status: String
    let tone: StatusPill.Tone
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    StatusPill(text: status, tone: tone)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Minimal toggle row

/// A full-width setting row: title, one-line subtitle, and a large switch.
/// The label and the switch are both part of the Toggle, so the whole row
/// behaves like one control without a second tap gesture.
struct BigToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.large)
        .disabled(!isEnabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.55)
    }
}
