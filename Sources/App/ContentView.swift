import AppKit
import SwiftUI

/// The entire UI. A 244x58 panel: "对方声音" + "麦克风" checkboxes, a small
/// state light with timer, and one small button (录制 / 暂停 / 继续 / 停止).
struct ContentView: View {
    @ObservedObject var viewModel: RecorderViewModel

    @State private var showFailure = false

    var body: some View {
        CompactRecorderPanel(
            model: model,
            onToggleRemote: { viewModel.remoteAudioEnabled = $0 },
            onToggleMic: { viewModel.settings.recordMicrophone = $0 },
            onPrimary: { viewModel.primaryAction() },
            onStop: { viewModel.stopRecording() },
            onOpen: { viewModel.openPrimaryFile() },
            onStatusTap: { statusTapped() }
        )
        .fixedSize()
        .onAppear { viewModel.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.refreshRouting()
        }
        .alert("无法开始录制", isPresented: startBlockBinding) {
            Button("打开系统设置") {
                viewModel.openSettingsForStartBlock()
                viewModel.startBlockAlert = nil
            }
            Button("好", role: .cancel) {
                viewModel.startBlockAlert = nil
            }
        } message: {
            Text(viewModel.startBlockAlert ?? "")
        }
        .alert("录制失败", isPresented: $showFailure) {
            Button("打开日志") { viewModel.revealDiagnostic() }
            Button("好", role: .cancel) {}
        } message: {
            Text(failureMessage)
        }
    }

    // MARK: Model mapping

    private var model: CompactPanelModel {
        CompactPanelModel(
            phase: phase,
            remoteOn: viewModel.remoteAudioEnabled,
            micOn: viewModel.settings.recordMicrophone,
            elapsedText: viewModel.compactElapsedText
        )
    }

    private var phase: CompactPanelModel.Phase {
        switch viewModel.uiState {
        case .idle: return .idle
        case .preparing: return .preparing
        case .recording: return .recording
        case .paused: return .paused
        case .stopping, .muxing: return .saving
        case .finished: return .finished
        case .failed: return .failed
        }
    }

    private var startBlockBinding: Binding<Bool> {
        Binding(
            get: { viewModel.startBlockAlert != nil },
            set: { if !$0 { viewModel.startBlockAlert = nil } }
        )
    }

    private var failureMessage: String {
        guard let failure = viewModel.lastFailure else { return "未知错误。" }
        return failure.detail.isEmpty ? failure.title : "\(failure.title)\n\n\(failure.detail)"
    }

    private func statusTapped() {
        switch viewModel.uiState {
        case .finished:
            viewModel.openPrimaryFile()
        case .failed:
            showFailure = true
        default:
            break
        }
    }
}
