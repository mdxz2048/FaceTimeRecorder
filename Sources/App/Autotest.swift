import Foundation
import AppKit
import CoreAudio

/// Coordinator-only integration hook. It runs the real app pipeline (same
/// bundle identity, same TCC grant) without UI clicks:
///
///   open "FaceTime Recorder.app" --args --autotest 8 --autotest-tone
///
/// This is not a product feature; it exists so the coordinator can verify the
/// audio/video/mux path with the permissions the user granted to the app.
extension RecorderViewModel {
    func runAutotestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--autotest") else { return }
        let seconds = max(2, Double(arguments[safe: index + 1] ?? "") ?? 8)
        let wantsVideo = arguments.contains("--autotest-video")
        let noMic = arguments.contains("--autotest-no-mic")
        let noMonitor = arguments.contains("--autotest-no-monitor")
        let wantsTone = arguments.contains("--autotest-tone")
        let takeover = arguments.contains("--autotest-takeover")
        let noAEC = arguments.contains("--autotest-no-aec")
        let pauseSeconds = arguments.contains("--autotest-pause") ? 3.0 : 0

        Task { @MainActor in
            self.appendAutotestProgress("task start")
            self.refreshDevices()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if self.settings.remoteDeviceUID.isEmpty || self.settings.recordVideo != wantsVideo {
                if let homePod = self.homePodDevice {
                    self.settings.remoteDeviceUID = homePod.uid
                }
            }
            self.settings.recordVideo = wantsVideo
            self.settings.recordMicrophone = !noMic
            self.settings.monitorEnabled = !noMonitor
            self.settings.takeOverSystemOutput = takeover
            self.settings.echoCancellation = noAEC ? .off : .appleVoiceProcessing
            self.settings.captureMode = .display
            if self.settings.captureDisplayID == nil {
                self.settings.captureDisplayID = self.displayOptions.first?.id
            }
            if self.settings.microphoneUID == nil,
               let input = AudioDeviceCatalog.defaultInputDeviceID() {
                self.settings.microphoneUID = CA.string(input, kAudioDevicePropertyDeviceUID)
            }
            if self.settings.monitorOutputUID == nil,
               let output = AudioDeviceCatalog.defaultOutputUID(),
               output != self.settings.remoteDeviceUID {
                self.settings.monitorOutputUID = output
            }
            self.appendAutotestProgress("settings remote=\(self.settings.remoteDeviceUID) mic=\(self.settings.microphoneUID ?? "nil") monitor=\(self.settings.monitorOutputUID ?? "nil") video=\(self.settings.recordVideo) micOn=\(self.settings.recordMicrophone) monitorOn=\(self.settings.monitorEnabled)")
            self.appendAutotestProgress("blockReason=\(self.startBlockReason ?? "nil") busy=\(self.uiState.isBusy) selfTesting=\(self.isSelfTesting) state=\(self.uiState)")
            var tone: TonePlayer?
            if wantsTone, !self.settings.remoteDeviceUID.isEmpty {
                let player = TonePlayer()
                if (try? player.start(deviceUID: self.settings.remoteDeviceUID,
                                      frequency: 440,
                                      amplitude: 0.05,
                                      duration: seconds + 8,
                                      sampleRate: 48_000)) != nil {
                    tone = player
                }
            }

            self.startRecording()
            self.appendAutotestProgress("startRecording returned state=\(self.uiState) failure=\(self.lastFailure?.title ?? "nil")")
            let startDeadline = Date().addingTimeInterval(20)
            while Date() < startDeadline,
                  self.uiState != .recording,
                  self.uiState != .failed {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if self.uiState == .recording {
                if pauseSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64((seconds / 2) * 1_000_000_000))
                    self.appendAutotestProgress("pause at state=\(self.uiState)")
                    self.pauseRecording()
                    try? await Task.sleep(nanoseconds: UInt64(pauseSeconds * 1_000_000_000))
                    self.appendAutotestProgress("resume at state=\(self.uiState)")
                    self.resumeRecording()
                    try? await Task.sleep(nanoseconds: UInt64((seconds / 2) * 1_000_000_000))
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
                self.stopRecording()
            } else {
                self.writeAutotestResult()
                try? await Task.sleep(nanoseconds: 800_000_000)
                NSApp.terminate(nil)
                return
            }
            let stopDeadline = Date().addingTimeInterval(45)
            while Date() < stopDeadline,
                  self.uiState != .finished,
                  self.uiState != .failed {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            tone?.stop()
            self.writeAutotestResult()
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApp.terminate(nil)
        }
    }

    private func writeAutotestResult() {
        var payload: [String: Any] = [
            "state": String(describing: self.uiState),
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let failure = self.lastFailure {
            payload["failureTitle"] = failure.title
            payload["failureDetail"] = failure.detail
        }
        if let reason = self.startBlockReason {
            payload["startBlockReason"] = reason
        }
        payload["progress"] = (try? String(contentsOfFile: "/tmp/fr-autotest-progress.txt",
                                           encoding: .utf8)) ?? ""
        if let result = self.lastResult {
            payload["sessionDirectory"] = result.sessionDirectory.path
            payload["mkv"] = result.mkvURL?.path ?? ""
            payload["mp4"] = result.mp4URL?.path ?? ""
            payload["remoteWAV"] = result.remoteWAVURL?.path ?? ""
            payload["micWAV"] = result.micWAVURL?.path ?? ""
            payload["diagnostics"] = result.diagnosticsURL.path
            payload["durationSeconds"] = result.durationSeconds
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/fr-autotest-result.json"))
        }
    }

    private func appendAutotestProgress(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/fr-autotest-progress.txt") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: "/tmp/fr-autotest-progress.txt"))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
