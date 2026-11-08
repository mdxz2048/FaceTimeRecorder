import AppKit
import SwiftUI

// MARK: - Model

struct CompactPanelModel: Equatable {
    enum Phase: String {
        case idle
        case preparing
        case recording
        case paused
        case saving
        case finished
        case failed
    }

    var phase: Phase = .idle
    var remoteOn: Bool = true
    var micOn: Bool = true
    var elapsedText: String = "00:00"
    /// Only used by the preview renderer; nil means "animate normally".
    var blinkOverride: Bool? = nil
}

// MARK: - Palette

enum CompactPalette {
    static let blue = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.231, blue: 0.188)
    static let amber = Color(red: 1.0, green: 0.584, blue: 0.0)
    static let idleDot = Color(red: 0.62, green: 0.62, blue: 0.65)
    static let label = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let secondary = Color(red: 0.42, green: 0.42, blue: 0.45)
    static let boxBorder = Color(red: 0.36, green: 0.36, blue: 0.39)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let quietFill = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let stopFill = Color(red: 1.0, green: 0.231, blue: 0.188).opacity(0.12)
}

// MARK: - Panel

/// One row of content, shown below the window's titlebar so the traffic lights
/// always sit on their own line: two checkboxes, the state light with timer,
/// and the action buttons.
struct CompactRecorderPanel: View {
    var model: CompactPanelModel
    var onToggleRemote: (Bool) -> Void = { _ in }
    var onToggleMic: (Bool) -> Void = { _ in }
    var onPrimary: () -> Void = {}
    var onStop: () -> Void = {}
    var onOpen: () -> Void = {}
    var onStatusTap: () -> Void = {}

    static let width: CGFloat = 392
    static let height: CGFloat = 46

    private var locked: Bool {
        switch model.phase {
        case .recording, .paused, .preparing, .saving:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            SmallCheckbox(title: "对方声音",
                          isOn: model.remoteOn,
                          enabled: !locked,
                          action: onToggleRemote)
            SmallCheckbox(title: "麦克风",
                          isOn: model.micOn,
                          enabled: !locked,
                          action: onToggleMic)
            Spacer(minLength: 10)
            statusLine
            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: Self.width, height: Self.height)
        .background(CompactPalette.background)
    }

    // MARK: Buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch model.phase {
        case .idle:
            CompactButton(title: "录制", kind: .primary, action: onPrimary)
        case .preparing:
            CompactButton(title: "准备", kind: .busy, action: {})
        case .saving:
            CompactButton(title: "保存中", kind: .busy, action: {})
        case .recording:
            HStack(spacing: 6) {
                CompactButton(title: "暂停", kind: .quiet, action: onPrimary)
                CompactButton(title: "停止", kind: .stop, action: onStop)
            }
        case .paused:
            HStack(spacing: 6) {
                CompactButton(title: "继续", kind: .primary, action: onPrimary)
                CompactButton(title: "停止", kind: .stop, action: onStop)
            }
        case .finished:
            HStack(spacing: 6) {
                CompactButton(title: "打开", kind: .primary, action: onOpen)
                CompactButton(title: "录制", kind: .quiet, action: onPrimary)
            }
        case .failed:
            HStack(spacing: 6) {
                CompactButton(title: "日志", kind: .quiet, action: onStatusTap)
                CompactButton(title: "重录", kind: .primary, action: onPrimary)
            }
        }
    }

    // MARK: Status

    private var statusLine: some View {
        Button(action: onStatusTap) {
            HStack(spacing: 5) {
                if model.phase == .saving {
                    TinySpinner()
                } else {
                    BlinkDot(active: model.phase == .recording,
                             color: dotColor,
                             size: 7,
                             override: model.blinkOverride)
                }
                if !statusText.isEmpty, model.phase != .saving {
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CompactPalette.secondary)
                }
                Text(model.elapsedText)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CompactPalette.label)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(statusHelp)
    }

    private var dotColor: Color {
        switch model.phase {
        case .recording: return CompactPalette.red
        case .paused: return CompactPalette.amber
        case .failed: return CompactPalette.red
        case .finished: return CompactPalette.blue
        case .idle, .preparing, .saving: return CompactPalette.idleDot
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return ""
        case .preparing: return "准备"
        case .recording: return ""
        case .paused: return "暂停"
        case .saving: return "保存中"
        case .finished: return "已保存"
        case .failed: return "未保存"
        }
    }

    private var statusHelp: String {
        switch model.phase {
        case .finished: return "打开视频"
        case .failed: return "查看失败原因"
        default: return ""
        }
    }
}

// MARK: - Pieces

struct BlinkDot: View {
    let active: Bool
    let color: Color
    var size: CGFloat = 6
    var override: Bool? = nil

    var body: some View {
        Group {
            if active, override == nil {
                TimelineView(.periodic(from: .now, by: 0.32)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.32) % 2 == 0
                    dot.opacity(on ? 1 : 0.22)
                }
            } else {
                dot.opacity(override == false ? 0.22 : 1)
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Hand-drawn spinner: the system ProgressView renders as a "no entry" glyph in
/// offscreen renders, and this keeps the app and its previews identical.
struct TinySpinner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.0) * 360
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(CompactPalette.secondary,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(turn))
                .frame(width: 9, height: 9)
        }
    }
}

struct SmallCheckbox: View {
    let title: String
    let isOn: Bool
    var enabled: Bool = true
    let action: (Bool) -> Void

    var body: some View {
        Button {
            action(!isOn)
        } label: {
            HStack(spacing: 6) {
                box
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(CompactPalette.label)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(isOn ? CompactPalette.blue : Color.clear)
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(isOn ? CompactPalette.blue : CompactPalette.boxBorder,
                              lineWidth: 1.3)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct CompactButton: View {
    enum Kind: Equatable {
        case primary
        case quiet
        case stop
        case busy
    }

    let title: String
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(minWidth: 38, minHeight: 26)
                .padding(.horizontal, 7)
                .background(Capsule(style: .continuous).fill(background))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(kind == .busy)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .quiet, .busy: return CompactPalette.label
        case .stop: return CompactPalette.red
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return CompactPalette.blue
        case .quiet, .busy: return CompactPalette.quietFill
        case .stop: return CompactPalette.stopFill
        }
    }
}
