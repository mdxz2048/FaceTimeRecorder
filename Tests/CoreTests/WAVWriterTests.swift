import XCTest

/// Offline tests for the 32-bit float WAV writer/reader.
final class WAVWriterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceTimeRecorder-WAV-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func url(_ name: String = "test.wav") -> URL {
        directory.appendingPathComponent(name)
    }

    private func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
        String(data: data.subdata(in: offset..<(offset + length)),
               encoding: .ascii) ?? ""
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    func testHeaderFieldsForEmptyStereoFile() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        try writer.close()

        let data = try Data(contentsOf: url())
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(ascii(data, 0, 4), "RIFF")
        XCTAssertEqual(u32(data, 4), 36, "RIFF size = data(0) + 36")
        XCTAssertEqual(ascii(data, 8, 4), "WAVE")
        XCTAssertEqual(ascii(data, 12, 4), "fmt ")
        XCTAssertEqual(u32(data, 16), 16, "PCM fmt chunk size")
        XCTAssertEqual(u16(data, 20), 3, "WAVE_FORMAT_IEEE_FLOAT")
        XCTAssertEqual(u16(data, 22), 2)
        XCTAssertEqual(u32(data, 24), 48_000)
        XCTAssertEqual(u32(data, 28), 384_000, "byte rate = 48000 * 2 * 4")
        XCTAssertEqual(u16(data, 32), 8, "block align = 2 * 4")
        XCTAssertEqual(u16(data, 34), 32)
        XCTAssertEqual(ascii(data, 36, 4), "data")
        XCTAssertEqual(u32(data, 40), 0)
    }

    func testHeaderAndDurationArePatchedOnClose() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        let frames = 480
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            samples[frame * 2] = Float(frame) / Float(frames)
            samples[frame * 2 + 1] = -samples[frame * 2]
        }
        try writer.write(samples)

        XCTAssertEqual(writer.framesWritten, UInt64(frames))
        XCTAssertEqual(writer.durationSeconds, 0.01, accuracy: 1e-12)
        try writer.close()

        let data = try Data(contentsOf: url())
        XCTAssertEqual(data.count, 44 + frames * 2 * 4)
        XCTAssertEqual(u32(data, 4), UInt32(36 + frames * 2 * 4))
        XCTAssertEqual(u32(data, 40), UInt32(frames * 2 * 4))

        let info = try WAVReader.info(url: url())
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.bitsPerSample, 32)
        XCTAssertEqual(info.dataBytes, UInt64(frames * 2 * 4))
        XCTAssertEqual(info.durationSeconds, 0.01, accuracy: 1e-12)
    }

    func testFloat32StereoRoundTrip() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        let values: [Float] = [0.5, -0.5, 0.25, -0.25, -1.0, 1.0, 0.0, 0.0]
        try writer.write(values)
        try writer.close()

        let data = try Data(contentsOf: url())
        XCTAssertEqual(data.count, 44 + values.count * 4)
        for index in 0..<values.count {
            let bits = u32(data, 44 + index * 4)
            XCTAssertEqual(Float(bitPattern: bits), values[index],
                           "sample \(index) must round-trip bit-exactly")
        }
    }

    func testMonoFileHasCorrectHeaderAndDuration() throws {
        let writer = try WAVWriter(url: url("mono.wav"), sampleRate: 48_000, channels: 1)
        try writer.write([Float](repeating: 0.1, count: 100))
        try writer.close()

        let data = try Data(contentsOf: url("mono.wav"))
        XCTAssertEqual(u16(data, 22), 1)
        XCTAssertEqual(u32(data, 28), 192_000, "byte rate = 48000 * 1 * 4")
        XCTAssertEqual(u16(data, 32), 4)
        XCTAssertEqual(u32(data, 40), 400)

        let info = try WAVReader.info(url: url("mono.wav"))
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.durationSeconds, 100.0 / 48_000.0, accuracy: 1e-12)
    }

    func testDurationAtFortyFourOne() throws {
        let writer = try WAVWriter(url: url("44k.wav"), sampleRate: 44_100, channels: 2)
        try writer.write([Float](repeating: 0, count: 44_100 * 2))
        XCTAssertEqual(writer.durationSeconds, 1.0, accuracy: 1e-12)
        try writer.close()

        let info = try WAVReader.info(url: url("44k.wav"))
        XCTAssertEqual(info.sampleRate, 44_100)
        XCTAssertEqual(info.durationSeconds, 1.0, accuracy: 1e-12)
    }

    func testWriteAfterCloseThrows() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        try writer.write([0, 0])
        try writer.close()

        XCTAssertThrowsError(try writer.write([0, 0])) { error in
            guard case WAVWriterError.closed = error else {
                return XCTFail("expected WAVWriterError.closed, got \(error)")
            }
        }
    }

    func testCloseIsIdempotent() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        try writer.write([0.25, -0.25])
        try writer.close()
        XCTAssertNoThrow(try writer.close())
        XCTAssertEqual(writer.framesWritten, 1)
    }

    func testInvalidConfigurationIsRejected() {
        XCTAssertThrowsError(try WAVWriter(url: url("a.wav"), sampleRate: 48_000, channels: 0))
        XCTAssertThrowsError(try WAVWriter(url: url("b.wav"), sampleRate: 48_000, channels: 33))
        XCTAssertThrowsError(try WAVWriter(url: url("c.wav"), sampleRate: 0, channels: 2))
        XCTAssertThrowsError(try WAVWriter(url: url("d.wav"), sampleRate: -1, channels: 2))
    }

    func testEmptyWriteIsNoOp() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        try writer.write([])
        XCTAssertEqual(writer.framesWritten, 0)
        try writer.close()

        let data = try Data(contentsOf: url())
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(u32(data, 40), 0)
    }

    func testExplicitZeroFrameWriteIsNoOp() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        let samples: [Float] = [1, 2, 3, 4]
        try writer.write(samples, frames: 0)
        XCTAssertEqual(writer.framesWritten, 0)
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: url()).count, 44)
    }

    /// Characterisation of the crash-recovery gap documented as QA-004: the
    /// data chunk length stays 0 until close(). The audio bytes are already on
    /// disk, but a process killed before close leaves a header that reports
    /// zero duration.
    func testHeaderDataSizeStaysZeroUntilClose() throws {
        let writer = try WAVWriter(url: url(), sampleRate: 48_000, channels: 2)
        try writer.write([Float](repeating: 0.25, count: 10 * 2))

        let beforeClose = try Data(contentsOf: url())
        XCTAssertEqual(beforeClose.count, 44 + 10 * 2 * 4)
        XCTAssertEqual(u32(beforeClose, 40), 0,
                       "current behaviour: data size is only patched by close()")

        try writer.close()
        let afterClose = try Data(contentsOf: url())
        XCTAssertEqual(u32(afterClose, 40), 80)
    }
}
