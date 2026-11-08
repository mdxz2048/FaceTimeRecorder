import Foundation
import CoreAudio
import Darwin
import os

private let toolVersion = "1.0.0"

private struct ProbeOptions {
    var command = "list"
    var uid: String?
    var seconds: Double = 10
    var wavPath: String?
    var reportPath: String?
    var json = false
    var tone = false
    var toneDeviceUID: String?
    var channels: [Int]?
    var allChannels = false
    var outputDirectory: String?
    var monitorUID: String?
    var microphoneUID: String?
    var disableMonitor = false
    var disableMicrophone = false
    var disableSelfTest = false
    var takeOverSystemOutput = false
}

private func usage() {
    print("""
    AudioProbe \(toolVersion) — Core Audio device / capture probe for FaceTime Recorder

    USAGE
      AudioProbe list [--json]
      AudioProbe tap --uid <device-uid> [options]
      AudioProbe input --uid <device-uid> [options]

    OPTIONS
      --seconds <n>        capture duration (default 10; use 300 for the 5-minute gate)
      --wav <path>         write captured PCM to a 32-bit float WAV
      --report <path>      write a JSON report
      --json               machine-readable device list / report on stdout
      --tone               play a 1 kHz tone into the tapped device while capturing
      --tone-device <uid>  tone output device (default: the tapped device)
      --channels 0,1       channels to write to WAV (default: first two)
      --all-channels       write every captured channel to WAV

    NOTES
      * `tap` uses CATapDescription(andDeviceUID:) and therefore needs the
        system audio-recording (TCC) permission. Without it the HAL still
        delivers callbacks but every sample is zero; the report says
        `all_zero_pcm` instead of pretending capture worked.
      * `input` reads a physical device's input stream directly.
      * Run the app bundle (Scripts/package-probe.sh) via `open` to receive the
        permission prompt. Running this binary from sshd alone has no TCC grant.
    """)
}

private func parseOptions(_ args: [String]) -> ProbeOptions {
    var options = ProbeOptions()
    var index = 0
    if let first = args.first, !first.hasPrefix("-") {
        options.command = first
        index = 1
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--uid":
            index += 1
            if index < args.count { options.uid = args[index] }
        case "--seconds", "-s":
            index += 1
            if index < args.count { options.seconds = Double(args[index]) ?? 10 }
        case "--wav":
            index += 1
            if index < args.count { options.wavPath = args[index] }
        case "--report":
            index += 1
            if index < args.count { options.reportPath = args[index] }
        case "--json":
            options.json = true
        case "--tone":
            options.tone = true
        case "--tone-device":
            index += 1
            if index < args.count { options.toneDeviceUID = args[index] }
        case "--channels":
            index += 1
            if index < args.count {
                options.channels = args[index].split(separator: ",").compactMap { Int($0) }
            }
        case "--all-channels":
            options.allChannels = true
        case "--output":
            index += 1
            if index < args.count { options.outputDirectory = args[index] }
        case "--monitor-uid":
            index += 1
            if index < args.count { options.monitorUID = args[index] }
        case "--mic-uid":
            index += 1
            if index < args.count { options.microphoneUID = args[index] }
        case "--no-monitor":
            options.disableMonitor = true
        case "--no-mic":
            options.disableMicrophone = true
        case "--no-selftest":
            options.disableSelfTest = true
        case "--takeover":
            options.takeOverSystemOutput = true
        case "--help", "-h":
            usage(); exit(0)
        default:
            if !arg.hasPrefix("-") { options.command = arg }
        }
        index += 1
    }
    return options
}

private func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func printDevices(json: Bool) {
    let devices = AudioDeviceCatalog.allDevices()
    if json {
        if let data = try? jsonEncoder().encode(devices.map(DeviceSnapshot.init)),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }
    print("Audio devices: \(devices.count)")
    for device in devices {
        print("")
        print("[\(device.id)] \(device.name)")
        print("  UID        : \(device.uid)")
        print("  model      : \(device.modelUID ?? "-")")
        print("  transport  : \(device.transportName) (0x\(String(device.transport, radix: 16)))")
        print("  direction  : in=\(device.inputChannels)ch / out=\(device.outputChannels)ch")
        print("  sampleRate : \(Int(device.nominalSampleRate)) Hz")
        print("  buffer     : \(device.bufferFrameSize.map(String.init) ?? "-") frames")
        print("  latency    : device=\(device.deviceLatencyFrames ?? 0) safety=\(device.safetyOffsetFrames ?? 0) frames")
        for stream in device.inputStreams {
            print("  in  stream \(stream.id): \(stream.virtualFormat.descriptionLine)")
        }
        for stream in device.outputStreams {
            print("  out stream \(stream.id): \(stream.virtualFormat.descriptionLine)")
        }
        if device.outputChannels > 0 {
            print("  labels     : \(device.preferredOutputChannelLabels.joined(separator: " "))")
        }
        if device.isHomePodFlowDevice {
            print("  NOTE       : HomePod Flow virtual device (reused, never modified by this tool)")
        }
    }
}

private struct ChannelMetrics {
    var sumSquares: Double = 0
    var peak: Float = 0
    var nonzero: UInt64 = 0
}

private struct CaptureSummary: Codable {
    var callbacks: UInt64 = 0
    var frames: UInt64 = 0
    var zeroFrames: UInt64 = 0
    var droppedBlocks: UInt64 = 0
    var firstHostTime: UInt64 = 0
    var lastHostTime: UInt64 = 0
    var durationSeconds: Double = 0
    var expectedFrames: Double = 0
    var lostFramesEstimate: Double = 0
    var rms: [Float] = []
    var peak: [Float] = []
    var peakDBFS: [Float] = []
    var nonzeroSamples: [UInt64] = []
    var allSilent: Bool = true
    var timestampFlags: UInt32 = 0
}

private struct Verdict: Codable {
    var callbacksAlive: Bool
    var pcmNonZero: Bool
    var code: String
    var explanation: String
}

private struct ProbeReport: Codable {
    var tool: String
    var version: String
    var schemaVersion: Int
    var generatedAt: Date
    var host: [String: String]
    var mode: String
    var device: DeviceSnapshot
    var tap: TapDescriptor?
    var requestedSeconds: Double
    var capture: CaptureSummary
    var tone: [String: String]?
    var wavPath: String?
    var wavInfo: WAVHeaderInfo?
    var verdict: Verdict
}

private func timebaseSeconds(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
}

private func dbfs(_ value: Float) -> Float {
    value <= 0 ? -120 : 20 * log10(value)
}

private func runCapture(options: ProbeOptions) -> Int32 {
    guard let uid = options.uid else {
        FileHandle.standardError.write(Data("error: --uid is required\n".utf8))
        return 2
    }
    guard let deviceInfo = AudioDeviceCatalog.allDevices().first(where: { $0.uid == uid }) else {
        FileHandle.standardError.write(Data("error: device UID not found: \(uid)\n".utf8))
        return 3
    }

    var originalDefaultOutput: String?
    if options.takeOverSystemOutput {
        originalDefaultOutput = AudioDeviceCatalog.defaultOutputUID()
        if originalDefaultOutput != uid {
            do {
                try AudioDeviceCatalog.setDefaultOutput(uid: uid)
                print("System output    : switched to \(uid) for the test")
            } catch {
                FileHandle.standardError.write(Data("could not switch system output: \(error)\n".utf8))
            }
        }
    }
    defer {
        if let originalDefaultOutput, originalDefaultOutput != uid {
            try? AudioDeviceCatalog.setDefaultOutput(uid: originalDefaultOutput)
            print("System output    : restored to \(originalDefaultOutput)")
        }
    }

    let isTap = options.command == "tap" || options.command == "probe"
    if isTap && deviceInfo.outputChannels == 0 {
        FileHandle.standardError.write(Data("error: \(uid) has no output stream; tap mode needs an output device\n".utf8))
        return 3
    }
    if !isTap && deviceInfo.inputChannels == 0 {
        FileHandle.standardError.write(Data("error: \(uid) has no input stream; use `tap` for output devices\n".utf8))
        return 3
    }

    print("Probe mode      : \(options.command)")
    print("Device          : \(deviceInfo.name)")
    print("UID             : \(deviceInfo.uid)")
    print("Direction       : in=\(deviceInfo.inputChannels) / out=\(deviceInfo.outputChannels)")
    print("Nominal rate    : \(Int(deviceInfo.nominalSampleRate)) Hz")
    print("Buffer frames   : \(deviceInfo.bufferFrameSize.map(String.init) ?? "-")")
    print("Requested time  : \(options.seconds) s")

    let tap = isTap ? DeviceTapCapture() : nil
    let input = isTap ? nil : DirectInputCapture()
    let sampleRate: Double
    let channels: Int
    let tapDescriptor: TapDescriptor?
    do {
        if let tap {
            let descriptor = try tap.start(deviceUID: uid)
            tapDescriptor = descriptor
            sampleRate = descriptor.sampleRate
            channels = Int(descriptor.channels)
            print("Tap UID         : \(descriptor.tapUID)")
            print("Tap format      : \(Int(descriptor.sampleRate)) Hz, \(descriptor.channels) ch")
            print("Aggregate clock : \(descriptor.clockDeviceUID)")
        } else if let input {
            let format = try input.start(deviceUID: uid)
            tapDescriptor = nil
            sampleRate = format.mSampleRate
            channels = Int(format.mChannelsPerFrame)
            print("Input format    : \(format.descriptionLine)")
        } else {
            return 4
        }
    } catch {
        FileHandle.standardError.write(Data("capture start failed: \(error)\n".utf8))
        return 4
    }

    let selectedChannels: [Int]
    if options.allChannels {
        selectedChannels = Array(0..<channels)
    } else if let requested = options.channels {
        selectedChannels = requested.filter { $0 >= 0 && $0 < channels }
    } else {
        selectedChannels = Array(0..<min(2, channels))
    }
    print("WAV channels    : \(selectedChannels.map(String.init).joined(separator: ","))")

    var writer: WAVWriter?
    if let path = options.wavPath {
        do {
            writer = try WAVWriter(url: URL(fileURLWithPath: path),
                                   sampleRate: sampleRate,
                                   channels: selectedChannels.count)
            print("WAV output      : \(path)")
        } catch {
            FileHandle.standardError.write(Data("WAV open failed: \(error)\n".utf8))
            tap?.stop(); input?.stop()
            return 5
        }
    }

    var tonePlayer: TonePlayer?
    var toneDescription: [String: String]?
    if options.tone {
        let toneUID = options.toneDeviceUID ?? uid
        let player = TonePlayer()
        do {
            try player.start(deviceUID: toneUID,
                             frequency: 1_000,
                             amplitude: 0.08,
                             duration: options.seconds + 1.0,
                             sampleRate: sampleRate)
            tonePlayer = player
            toneDescription = ["deviceUID": toneUID, "frequencyHz": "1000",
                               "amplitude": "0.08"]
            print("Self-test tone  : 1 kHz -> \(toneUID)")
        } catch {
            print("Self-test tone  : FAILED (\(error))")
            toneDescription = ["error": "\(error)"]
        }
    }

    var summary = CaptureSummary()
    var metrics = [ChannelMetrics](repeating: ChannelMetrics(), count: channels)
    var scratch = [Float](repeating: 0, count: 16_384 * max(channels, 1))
    var selected = [Float](repeating: 0, count: 16_384 * max(selectedChannels.count, 1))
    let startedAt = Date()
    let deadline = Date().addingTimeInterval(options.seconds)
    var lastReport = Date()
    var lastCallbackCount: UInt64 = 0
    var lastFrameCount: UInt64 = 0

    while Date() < deadline {
        var didWork = false
        do {
            let block: CapturedBlock?
            if let tap { block = try tap.readBlock(into: &scratch) }
            else if let input { block = try input.readBlock(into: &scratch) }
            else { block = nil }
            if let block, block.frames > 0 {
                didWork = true
                summary.callbacks += 1
                summary.frames += UInt64(block.frames)
                summary.droppedBlocks = max(summary.droppedBlocks, block.droppedBefore)
                summary.timestampFlags = block.timestampFlags
                if summary.firstHostTime == 0 { summary.firstHostTime = block.hostTime }
                summary.lastHostTime = block.hostTime
                let blockChannels = min(block.channels, channels)
                for frame in 0..<block.frames {
                    var frameNonzero = false
                    for channel in 0..<blockChannels {
                        let value = block.samples[frame * block.channels + channel]
                        if value != 0 {
                            frameNonzero = true
                            metrics[channel].nonzero += 1
                        }
                        metrics[channel].sumSquares += Double(value * value)
                        metrics[channel].peak = max(metrics[channel].peak, abs(value))
                    }
                    if !frameNonzero { summary.zeroFrames += 1 }
                }
                if let writer {
                    for frame in 0..<block.frames {
                        for (outIndex, channel) in selectedChannels.enumerated() {
                            selected[frame * selectedChannels.count + outIndex] =
                                channel < block.channels
                                ? block.samples[frame * block.channels + channel] : 0
                        }
                    }
                    try writer.write(selected,
                                     frames: block.frames)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("capture read failed: \(error)\n".utf8))
            break
        }

        if Date().timeIntervalSince(lastReport) >= 1.0 {
            let elapsed = Date().timeIntervalSince(lastReport)
            let frames = summary.frames
            let frameDelta = frames - lastFrameCount
            let cbDelta = summary.callbacks - lastCallbackCount
            lastFrameCount = frames
            lastCallbackCount = summary.callbacks
            let rms = metrics.map { Float(sqrt($0.sumSquares / Double(max(frames, 1)))) }
            let peaks = metrics.map(\.peak)
            let rmsText = rms.enumerated().map { "ch\($0.offset)=\(String(format: "%.4f", $0.element))" }.joined(separator: " ")
            print(String(format: "t=%5.1fs cb=%llu(+%llu) frames=%llu(+%llu) rate=%.0f/s rms[%@] peak=[%@]",
                         Date().timeIntervalSince(startedAt),
                         summary.callbacks, cbDelta, frames, frameDelta,
                         Double(frameDelta) / max(elapsed, 0.001),
                         rmsText,
                         peaks.map { String(format: "%.3f", $0) }.joined(separator: ",")))
            lastReport = Date()
        }
        if !didWork { usleep(5_000) }
    }

    tonePlayer?.stop()
    tap?.stop()
    input?.stop()
    try? writer?.close()

    if summary.firstHostTime > 0 {
        summary.durationSeconds = timebaseSeconds(summary.lastHostTime &- summary.firstHostTime)
    }
    summary.expectedFrames = summary.durationSeconds * sampleRate
    summary.lostFramesEstimate = max(0, summary.expectedFrames - Double(summary.frames))
    summary.rms = metrics.map { Float(sqrt($0.sumSquares / Double(max(summary.frames, 1)))) }
    summary.peak = metrics.map(\.peak)
    summary.peakDBFS = summary.peak.map(dbfs)
    summary.nonzeroSamples = metrics.map(\.nonzero)
    summary.allSilent = summary.nonzeroSamples.allSatisfy { $0 == 0 }

    let verdict: Verdict
    if summary.callbacks == 0 {
        verdict = Verdict(callbacksAlive: false, pcmNonZero: false,
                          code: "no_callbacks",
                          explanation: "The HAL never invoked the capture callback. Check device presence and that the aggregate device started.")
    } else if summary.frames == 0 {
        verdict = Verdict(callbacksAlive: true, pcmNonZero: false,
                          code: "no_frames",
                          explanation: "Callbacks fired but no complete audio block was queued.")
    } else if summary.allSilent {
        verdict = Verdict(callbacksAlive: true, pcmNonZero: false,
                          code: "all_zero_pcm",
                          explanation: "Callbacks and frames are healthy but every sample is exactly zero. For a device tap this is the signature of missing audio-capture (TCC) authorization, or nothing is rendering to the device. It is not proof that FaceTime audio works.")
    } else {
        verdict = Verdict(callbacksAlive: true, pcmNonZero: true,
                          code: "pcm_detected",
                          explanation: "Non-zero PCM was captured. Only a human listening test (and a real FaceTime call) can confirm content and routing.")
    }

    var wavInfo: WAVHeaderInfo?
    if let path = options.wavPath {
        wavInfo = try? WAVReader.info(url: URL(fileURLWithPath: path))
    }
    let report = ProbeReport(tool: "AudioProbe", version: toolVersion, schemaVersion: 1,
                             generatedAt: Date(),
                             host: ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                                    "arch": currentArchitecture()],
                             mode: options.command,
                             device: DeviceSnapshot(deviceInfo),
                             tap: tapDescriptor, requestedSeconds: options.seconds,
                             capture: summary, tone: toneDescription,
                             wavPath: options.wavPath, wavInfo: wavInfo, verdict: verdict)

    print("")
    print("Result          : \(verdict.code)")
    print("Callbacks       : \(summary.callbacks)")
    print("Frames          : \(summary.frames) (expected ≈ \(Int(summary.expectedFrames)), lost ≈ \(Int(summary.lostFramesEstimate)))")
    print("Dropped blocks  : \(summary.droppedBlocks)")
    print("Silent frames   : \(summary.zeroFrames) / \(summary.frames)")
    for channel in 0..<channels {
        print(String(format: "ch%d             : rms=%.6f peak=%.6f (%.1f dBFS) nonzero=%llu",
                     channel, summary.rms[channel], summary.peak[channel],
                     summary.peakDBFS[channel], summary.nonzeroSamples[channel]))
    }
    if let wavInfo {
        print(String(format: "WAV             : %.2f s, %d ch, %d Hz",
                     wavInfo.durationSeconds, wavInfo.channels, Int(wavInfo.sampleRate)))
    }
    print("Explanation     : \(verdict.explanation)")

    if let path = options.reportPath {
        do {
            let data = try jsonEncoder().encode(report)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Report          : \(path)")
        } catch {
            FileHandle.standardError.write(Data("report write failed: \(error)\n".utf8))
        }
    }
    if options.json, let data = try? jsonEncoder().encode(report),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    return verdict.pcmNonZero ? 0 : 10
}

private func runSession(options: ProbeOptions) -> Int32 {
    guard let uid = options.uid else {
        FileHandle.standardError.write(Data("error: --uid is required\n".utf8))
        return 2
    }
    let output = URL(fileURLWithPath: options.outputDirectory ?? "/tmp/facetime-recorder-session")
    let configuration = RecorderConfiguration(
        remoteDeviceUID: uid,
        microphoneUID: options.disableMicrophone ? nil
            : (options.microphoneUID ?? AudioDeviceCatalog.defaultInputDeviceID()
                .flatMap { CA.string($0, kAudioDevicePropertyDeviceUID) }),
        monitorOutputUID: options.monitorUID ?? AudioDeviceCatalog.defaultOutputUID(),
        captureDisplayID: nil,
        captureWindowID: nil,
        recordVideo: false,
        recordMicrophone: !options.disableMicrophone,
        monitorEnabled: !options.disableMonitor,
        monitorVolume: 0.5,
        echoCancellation: .appleVoiceProcessing,
        remoteChannelMode: .stereoDownmix,
        takeOverSystemOutput: options.takeOverSystemOutput,
        outputDirectory: output)

    let engine = RecorderEngine()
    var sessionTone: TonePlayer?
    if options.tone {
        let player = TonePlayer()
        if (try? player.start(deviceUID: uid,
                              frequency: 440,
                              amplitude: 0.05,
                              duration: max(2, options.seconds) + 2,
                              sampleRate: 48_000)) != nil {
            sessionTone = player
            print("session tone: 440 Hz -> \(uid)")
        }
    }
    do {
        let files = try engine.start(configuration: configuration,
                                     performSelfTest: !options.disableSelfTest)
        print("session started: \(files.directory.path)")
        let deadline = Date().addingTimeInterval(max(1, options.seconds))
        while Date() < deadline {
            let snapshot = engine.snapshot()
            print(String(format: "t=%.1fs remoteRMS=%.4f micRMS=%.4f fill=%d ovf=%llu under=%llu",
                         snapshot.elapsed, snapshot.remoteRMS, snapshot.micRMS,
                         snapshot.monitorFillFrames, snapshot.monitorOverflows,
                         snapshot.monitorUnderruns))
            Thread.sleep(forTimeInterval: 1)
        }
        guard let result = engine.stop() else {
            print("stop returned no result")
            sessionTone?.stop()
            return 6
        }
        sessionTone?.stop()
        print("session finished: \(result.sessionDirectory.path)")
        print("duration: \(String(format: "%.2f", result.durationSeconds)) s")
        if let mkv = result.mkvURL { print("mkv: \(mkv.path)") }
        if let diagnostics = try? Data(contentsOf: result.diagnosticsURL),
           let text = String(data: diagnostics, encoding: .utf8) {
            print("diagnostics: \(result.diagnosticsURL.path)")
            print(text)
        }
        return 0
    } catch {
        sessionTone?.stop()
        FileHandle.standardError.write(Data("session failed: \(error)\n".utf8))
        return 7
    }
}

private func currentArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

private let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
switch options.command {
case "list", "devices", "enumerate":
    printDevices(json: options.json)
    exit(0)
case "tap", "input", "probe":
    exit(runCapture(options: options))
case "session":
    exit(runSession(options: options))
default:
    usage()
    exit(2)
}
