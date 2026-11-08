import AppKit
import SwiftUI

@main
@MainActor
struct FaceTimeRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = RecorderViewModel()

    var body: some Scene {
        Window("FaceTime 录音", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(width: CompactRecorderPanel.width,
                       height: CompactRecorderPanel.height)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
                .task { viewModel.runAutotestIfRequested() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CompactRecorderPanel.width,
                     height: CompactRecorderPanel.height)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 FaceTime Recorder \(AppVersion.display)") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            RecorderCommands(viewModel: viewModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: RecorderViewModel?
    private var configureAttempts = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI creates the window after launch; give it a moment, then make
        // the content view span the full window so no titlebar strip is wasted.
        attemptConfigureWindow()
    }

    private func attemptConfigureWindow() {
        configureAttempts += 1
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            applyCompactFrame(to: window)
            return
        }
        guard configureAttempts < 25 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.attemptConfigureWindow()
        }
    }

    private func applyCompactFrame(to window: NSWindow) {
        // Keep the traffic lights on their own line above the panel content.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: CompactRecorderPanel.width,
                                     height: CompactRecorderPanel.height))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let viewModel = viewModel else { return .terminateNow }
            let shouldWait = viewModel.prepareForTermination {
                sender.reply(toApplicationShouldTerminate: true)
            }
            return shouldWait ? .terminateLater : .terminateNow
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct RecorderCommands: Commands {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some Commands {
        CommandMenu("录制") {
            Button("录制") {
                viewModel.startRecording()
            }
            .disabled(viewModel.uiState.isBusy)

            Button("暂停") {
                viewModel.pauseRecording()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(viewModel.uiState != .recording)

            Button("继续") {
                viewModel.resumeRecording()
            }
            .disabled(viewModel.uiState != .paused)

            Button("停止") {
                viewModel.stopRecording()
            }
            .disabled(viewModel.uiState != .recording && viewModel.uiState != .paused)
        }

        CommandMenu("音频") {
            Button("恢复默认音频输出") {
                viewModel.restoreDefaultOutput()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(viewModel.uiState.isBusy)

            Divider()

            Button("刷新音频设备") {
                viewModel.refreshDevices()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(viewModel.uiState.isBusy)

            Button("打开声音设置") {
                viewModel.openSystemSettings(.sound)
            }
        }
    }
}
