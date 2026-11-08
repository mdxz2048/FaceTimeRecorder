import XCTest

/// Offline tests for MediaMuxer.arguments. No ffmpeg process is started.
final class MuxArgumentsTests: XCTestCase {

    private let video = URL(fileURLWithPath: "/tmp/qa/screen.mov")
    private let remote = URL(fileURLWithPath: "/tmp/qa/remote.wav")
    private let mic = URL(fileURLWithPath: "/tmp/qa/microphone.wav")
    private let output = URL(fileURLWithPath: "/tmp/qa/FaceTime.mkv")

    private func index(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    private func count(of value: String, in haystack: [String]) -> Int {
        haystack.filter { $0 == value }.count
    }

    func testMkvWithAllThreeInputsMapsMixThenRemoteThenMic() {
        let args = MediaMuxer.arguments(video: video,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: output,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)

        XCTAssertEqual(Array(args.prefix(6)), ["-y", "-hide_banner", "-loglevel", "warning",
                                               "-i", video.path])
        XCTAssertEqual(count(of: "-map", in: args), 4)
        XCTAssertNotNil(index(of: ["-map", "0:v:0"], in: args))
        XCTAssertNotNil(index(of: ["-map", "[mix]"], in: args))
        XCTAssertNotNil(index(of: ["-map", "1:a:0"], in: args))
        XCTAssertNotNil(index(of: ["-map", "2:a:0"], in: args))
        XCTAssertNotNil(index(of: ["-c:v", "copy"], in: args))
        XCTAssertNotNil(index(of: ["-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2"],
                             in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:0", "title=Mix (Remote + Mic)"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:1", "title=Remote"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:2", "title=Microphone"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:v:0", "title=Screen"], in: args))
        XCTAssertNil(index(of: ["-movflags", "+faststart"], in: args))
        XCTAssertEqual(args.last, output.path)

        let filter = args[index(of: ["-filter_complex"], in: args)! + 1]
        XCTAssertEqual(filter,
                       "[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[rmt];"
                       + "[2:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[mic];"
                       + "[rmt][mic]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[mix]")
    }

    func testMp4WithAllThreeInputsExportsSingleMixTrack() {
        let mp4 = URL(fileURLWithPath: "/tmp/qa/FaceTime.mp4")
        let args = MediaMuxer.arguments(video: video,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: mp4,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mp4)

        XCTAssertEqual(count(of: "-map", in: args), 2)
        XCTAssertNotNil(index(of: ["-map", "0:v:0"], in: args))
        XCTAssertNotNil(index(of: ["-map", "[mix]"], in: args))
        XCTAssertNil(index(of: ["-map", "1:a:0"], in: args))
        XCTAssertNil(index(of: ["-map", "2:a:0"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:0", "title=Mix (Remote + Mic)"], in: args))
        XCTAssertNil(index(of: ["-metadata:s:a:1", "title=Remote"], in: args))
        XCTAssertNil(index(of: ["-metadata:s:a:2", "title=Microphone"], in: args))
        XCTAssertNil(index(of: ["-metadata:s:v:0", "title=Screen"], in: args))
        XCTAssertNotNil(index(of: ["-movflags", "+faststart"], in: args))
        XCTAssertEqual(args.last, mp4.path)
    }

    func testMkvWithoutVideoReindexesInputs() {
        let args = MediaMuxer.arguments(video: nil,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: output,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)

        XCTAssertEqual(count(of: "-i", in: args), 2)
        XCTAssertNotNil(index(of: ["-i", remote.path], in: args))
        XCTAssertNotNil(index(of: ["-i", mic.path], in: args))
        XCTAssertNotNil(index(of: ["-map", "[mix]"], in: args))
        XCTAssertNotNil(index(of: ["-map", "0:a:0"], in: args))
        XCTAssertNotNil(index(of: ["-map", "1:a:0"], in: args))
        XCTAssertNil(index(of: ["-c:v", "copy"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:1", "title=Remote"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:2", "title=Microphone"], in: args))

        let filter = args[index(of: ["-filter_complex"], in: args)! + 1]
        XCTAssertTrue(filter.hasPrefix("[0:a]"))
        XCTAssertTrue(filter.contains("[1:a]"))
    }

    func testVideoOnlyProducesNoAudioArguments() {
        let args = MediaMuxer.arguments(video: video,
                                        remoteWAV: nil,
                                        micWAV: nil,
                                        output: output,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)

        XCTAssertNil(index(of: ["-filter_complex"], in: args))
        XCTAssertEqual(count(of: "-map", in: args), 1)
        XCTAssertNotNil(index(of: ["-map", "0:v:0"], in: args))
        XCTAssertNotNil(index(of: ["-c:v", "copy"], in: args))
        XCTAssertNil(index(of: ["-c:a"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:v:0", "title=Screen"], in: args))
    }

    func testRemoteOnlyUsesAnullMixAndRemoteMetadata() {
        let args = MediaMuxer.arguments(video: nil,
                                        remoteWAV: remote,
                                        micWAV: nil,
                                        output: output,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)

        XCTAssertEqual(count(of: "-map", in: args), 2)
        XCTAssertNotNil(index(of: ["-map", "[mix]"], in: args))
        XCTAssertNotNil(index(of: ["-map", "0:a:0"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:1", "title=Remote"], in: args))
        XCTAssertNil(index(of: ["-metadata:s:a:2", "title=Microphone"], in: args))

        let filter = args[index(of: ["-filter_complex"], in: args)! + 1]
        XCTAssertEqual(filter,
                       "[0:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[rmt];"
                       + "[rmt]anull[mix]")
    }

    func testMicOnlyUsesAnullMixAndStreamOne() {
        let args = MediaMuxer.arguments(video: video,
                                        remoteWAV: nil,
                                        micWAV: mic,
                                        output: output,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)

        // Video map + mix map + mic map.
        XCTAssertEqual(count(of: "-map", in: args), 3)
        XCTAssertNotNil(index(of: ["-map", "[mix]"], in: args))
        XCTAssertNotNil(index(of: ["-map", "0:v:0"], in: args))
        XCTAssertNotNil(index(of: ["-map", "1:a:0"], in: args))
        XCTAssertNil(index(of: ["-metadata:s:a:1", "title=Remote"], in: args))
        XCTAssertNotNil(index(of: ["-metadata:s:a:1", "title=Microphone"], in: args))

        let filter = args[index(of: ["-filter_complex"], in: args)! + 1]
        XCTAssertEqual(filter,
                       "[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[mic];"
                       + "[mic]anull[mix]")
    }

    func testOffsetsArePlacedImmediatelyBeforeTheirInput() throws {
        let args = MediaMuxer.arguments(video: video,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: output,
                                        remoteOffset: 0.1,
                                        micOffset: 0.25,
                                        container: .mkv)

        let remoteOffset = try XCTUnwrap(index(of: ["-itsoffset", "0.1000", "-i", remote.path],
                                               in: args))
        let micOffset = try XCTUnwrap(index(of: ["-itsoffset", "0.2500", "-i", mic.path],
                                            in: args))
        XCTAssertLessThan(remoteOffset, micOffset)
        XCTAssertEqual(count(of: "-itsoffset", in: args), 2)
    }

    func testMkvMapOrderIsMixRemoteMic() throws {
        let args = MediaMuxer.arguments(video: nil,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: output,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)
        let mix = try XCTUnwrap(index(of: ["-map", "[mix]"], in: args))
        let remoteMap = try XCTUnwrap(index(of: ["-map", "0:a:0"], in: args))
        let micMap = try XCTUnwrap(index(of: ["-map", "1:a:0"], in: args))
        XCTAssertLessThan(mix, remoteMap)
        XCTAssertLessThan(remoteMap, micMap)
    }

    func testTinyAndNegativeOffsetsAreIgnored() {
        let tiny = MediaMuxer.arguments(video: video,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: output,
                                        remoteOffset: 0.0005,
                                        micOffset: -0.2,
                                        container: .mkv)
        XCTAssertEqual(count(of: "-itsoffset", in: tiny), 0)

        let included = MediaMuxer.arguments(video: video,
                                            remoteWAV: remote,
                                            micWAV: mic,
                                            output: output,
                                            remoteOffset: 0.0006,
                                            micOffset: 0,
                                            container: .mkv)
        XCTAssertNotNil(index(of: ["-itsoffset", "0.0006"], in: included))
        XCTAssertEqual(count(of: "-itsoffset", in: included), 1)
    }

    func testPathsWithSpacesArePassedAsSingleArguments() {
        let spacedOutput = URL(fileURLWithPath: "/tmp/qa/My Recording/FaceTime final.mkv")
        let args = MediaMuxer.arguments(video: video,
                                        remoteWAV: remote,
                                        micWAV: mic,
                                        output: spacedOutput,
                                        remoteOffset: 0,
                                        micOffset: 0,
                                        container: .mkv)
        XCTAssertEqual(args.last, spacedOutput.path)
        XCTAssertTrue(args.contains(spacedOutput.path))
    }

    func testMuxWithoutInputsThrowsBeforeRunningFFmpeg() {
        XCTAssertThrowsError(try MediaMuxer.mux(video: nil,
                                                remoteWAV: nil,
                                                micWAV: nil,
                                                output: output,
                                                container: .mkv)) { error in
            guard case MediaMuxerError.invalidInputs = error else {
                return XCTFail("expected MediaMuxerError.invalidInputs, got \(error)")
            }
        }
    }

    func testContainerRawValues() {
        XCTAssertEqual(MediaMuxer.Container.mkv.rawValue, "mkv")
        XCTAssertEqual(MediaMuxer.Container.mp4.rawValue, "mp4")
    }
}
