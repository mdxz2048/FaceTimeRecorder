import Foundation
import Darwin

// Usage: MuxHarness remote.wav mic.wav FaceTime.mp4 FaceTime.mkv
guard CommandLine.arguments.count == 5 else {
    FileHandle.standardError.write(
        Data("usage: MuxHarness remote.wav mic.wav FaceTime.mp4 FaceTime.mkv\n".utf8))
    exit(2)
}

let remote = URL(fileURLWithPath: CommandLine.arguments[1])
let mic = URL(fileURLWithPath: CommandLine.arguments[2])
let mp4 = URL(fileURLWithPath: CommandLine.arguments[3])
let mkv = URL(fileURLWithPath: CommandLine.arguments[4])

do {
    let mp4Result = try MediaMuxer.mux(video: nil,
                                       remoteWAV: remote,
                                       micWAV: mic,
                                       output: mp4,
                                       container: .mp4)
    let mkvResult = try MediaMuxer.mux(video: nil,
                                       remoteWAV: remote,
                                       micWAV: mic,
                                       output: mkv,
                                       container: .mkv)
    print("mp4 success=\(mp4Result.success) exit=\(mp4Result.exitCode) duration=\(mp4Result.durationSeconds ?? -1)")
    print("mkv success=\(mkvResult.success) exit=\(mkvResult.exitCode) duration=\(mkvResult.durationSeconds ?? -1)")
    if !mp4Result.success {
        FileHandle.standardError.write(Data(("mp4 stderr: " + mp4Result.stderrTail + "\n").utf8))
    }
    if !mkvResult.success {
        FileHandle.standardError.write(Data(("mkv stderr: " + mkvResult.stderrTail + "\n").utf8))
    }
    exit(mp4Result.success && mkvResult.success ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("mux threw: \(error)\n".utf8))
    exit(2)
}
