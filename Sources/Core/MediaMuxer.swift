import Foundation

public struct MuxResult: Sendable {
    public let success: Bool
    public let outputURL: URL?
    public let command: [String]
    public let exitCode: Int32
    public let stderrTail: String
    public let durationSeconds: Double?
}

public enum MediaMuxerError: Error, CustomStringConvertible {
    case ffmpegNotFound
    case invalidInputs

    public var description: String {
        switch self {
        case .ffmpegNotFound:
            return "未找到 ffmpeg。请安装（brew install ffmpeg）或设置 FFMPEG_PATH。"
        case .invalidInputs:
            return "没有可封装的输入轨道。"
        }
    }
}

/// Produces one deliverable from one session:
///   * MP4: H.264 video plus three AAC tracks — mix (default, plays normally),
///     Remote and Microphone. The isolated tracks are present for later
///     extraction but keep the default disposition off, so players only play
///     the mix. MKV remains available for archival/testing.
public enum MediaMuxer {
    public enum Container: String, Sendable {
        case mkv
        case mp4
    }

    public static func locateFFmpeg() -> String? {
        if let override = ProcessInfo.processInfo.environment["FFMPEG_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Pure argument builder so the mapping can be unit-tested without ffmpeg.
    /// Input order is always video (if any), remote (if any), mic (if any).
    public static func arguments(video: URL?,
                                 remoteWAV: URL?,
                                 micWAV: URL?,
                                 output: URL,
                                 remoteOffset: Double,
                                 micOffset: Double,
                                 container: Container) -> [String] {
        var args = ["-y", "-hide_banner", "-loglevel", "warning"]
        var inputIndex = 0
        var videoIndex: Int?
        var remoteIndex: Int?
        var micIndex: Int?
        if let video {
            args += ["-i", video.path]
            videoIndex = inputIndex; inputIndex += 1
        }
        if let remoteWAV {
            if remoteOffset > 0.0005 {
                args += ["-itsoffset", String(format: "%.4f", remoteOffset)]
            }
            args += ["-i", remoteWAV.path]
            remoteIndex = inputIndex; inputIndex += 1
        }
        if let micWAV {
            if micOffset > 0.0005 {
                args += ["-itsoffset", String(format: "%.4f", micOffset)]
            }
            args += ["-i", micWAV.path]
            micIndex = inputIndex; inputIndex += 1
        }

        let hasMix = remoteIndex != nil || micIndex != nil
        // Cleaned-up microphone: the built-in array reports very low level, so
        // lift it, tame the boxiness, and even it out before mixing. The same
        // processed signal is exported as the standalone Mic track.
        let micChain = "highpass=f=80,"
            + "equalizer=f=200:t=q:w=1:g=-2,"
            + "equalizer=f=3000:t=q:w=1:g=+2,"
            + "volume=20dB,"
            + "acompressor=threshold=-18dB:ratio=3:attack=5:release=120,"
            + "alimiter=limit=0.95"
        if hasMix {
            var filters: [String] = []
            var mixInputs: [String] = []
            if let remoteIndex {
                filters.append("[\(remoteIndex):a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[rmt]")
                mixInputs.append("[rmt]")
            }
            if let micIndex {
                filters.append("[\(micIndex):a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,\(micChain)[micp]")
                filters.append("[micp]asplit=2[micmix][micout]")
                mixInputs.append("[micmix]")
            }
            if mixInputs.count == 2 {
                filters.append("\(mixInputs.joined())amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[mix]")
            } else if let only = mixInputs.first {
                filters.append("\(only)anull[mix]")
            }
            args += ["-filter_complex", filters.joined(separator: ";")]
        }

        if let videoIndex {
            args += ["-map", "\(videoIndex):v:0"]
        }
        if hasMix {
            args += ["-map", "[mix]"]
        }
        var audioStream = 0
        var mixStream: Int?
        var remoteStream: Int?
        var micStream: Int?
        if hasMix {
            mixStream = audioStream
            audioStream += 1
        }
        if let remoteIndex {
            args += ["-map", "\(remoteIndex):a:0"]
            remoteStream = audioStream
            audioStream += 1
        }
        if let micIndex {
            args += ["-map", "[micout]"]
            micStream = audioStream
            audioStream += 1
        }
        if videoIndex != nil {
            args += ["-c:v", "copy"]
        }
        if let mixStream {
            args += ["-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2"]
            args += ["-metadata:s:a:\(mixStream)", "title=Mix (Remote + Mic)",
                     "-metadata:s:a:\(mixStream)", "handler_name=FaceTime Mix"]
        }
        if let remoteStream {
            args += ["-metadata:s:a:\(remoteStream)", "title=Remote",
                     "-metadata:s:a:\(remoteStream)", "handler_name=FaceTime Remote"]
        }
        if let micStream {
            args += ["-metadata:s:a:\(micStream)", "title=Microphone",
                     "-metadata:s:a:\(micStream)", "handler_name=Local Microphone"]
        }
        if videoIndex != nil {
            args += ["-metadata:s:v:0", "title=Screen",
                     "-metadata:s:v:0", "handler_name=Screen Capture"]
        }
        if container == .mp4 {
            if let mixStream {
                args += ["-disposition:a:\(mixStream)", "default"]
            }
            if let remoteStream {
                args += ["-disposition:a:\(remoteStream)", "0"]
            }
            if let micStream {
                args += ["-disposition:a:\(micStream)", "0"]
            }
            args += ["-movflags", "+faststart"]
        }
        args += ["-fflags", "+genpts", output.path]
        return args
    }

    public static func mux(video: URL?,
                           remoteWAV: URL?,
                           micWAV: URL?,
                           output: URL,
                           container: Container,
                           remoteOffset: Double = 0,
                           micOffset: Double = 0) throws -> MuxResult {
        guard video != nil || remoteWAV != nil || micWAV != nil else {
            throw MediaMuxerError.invalidInputs
        }
        guard let ffmpeg = locateFFmpeg() else { throw MediaMuxerError.ffmpegNotFound }
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let args = arguments(video: video, remoteWAV: remoteWAV, micWAV: micWAV,
                             output: output, remoteOffset: remoteOffset,
                             micOffset: micOffset, container: container)
        return run(ffmpeg: ffmpeg, args: args, output: output)
    }

    private static func run(ffmpeg: String, args: [String], output: URL) -> MuxResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return MuxResult(success: false, outputURL: nil,
                             command: [ffmpeg] + args, exitCode: -1,
                             stderrTail: error.localizedDescription,
                             durationSeconds: nil)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let tail = String(text.suffix(4_000))
        let success = process.terminationStatus == 0 &&
                      FileManager.default.fileExists(atPath: output.path)
        return MuxResult(success: success,
                         outputURL: success ? output : nil,
                         command: [ffmpeg] + args,
                         exitCode: process.terminationStatus,
                         stderrTail: tail,
                         durationSeconds: success ? probeDuration(output) : nil)
    }

    public static func probeDuration(_ url: URL) -> Double? {
        let ffprobe = URL(fileURLWithPath: (locateFFmpeg() ?? "/opt/homebrew/bin/ffmpeg")
            .replacingOccurrences(of: "/ffmpeg", with: "/ffprobe"))
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_entries", "format=duration",
                             "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Double(String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
