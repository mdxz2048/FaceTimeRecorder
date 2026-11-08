import XCTest

/// Offline tests for the C SPSC rings in Sources/CRing.
/// No Core Audio, no TCC, no hardware.
final class RingBufferTests: XCTestCase {

    // MARK: - Helpers

    private func makeSampleRing(capacity: UInt32 = 1_024,
                                channels: UInt32 = 2) throws -> OpaquePointer {
        try XCTUnwrap(fr_sample_ring_create(capacity, channels))
    }

    private func makeBlockRing(slots: UInt32 = 4,
                               maxFrames: UInt32 = 256,
                               channels: UInt32 = 2) throws -> OpaquePointer {
        try XCTUnwrap(fr_block_ring_create(slots, maxFrames, channels))
    }

    /// Interleaved ramp where frame `start + i`, channel `c` is
    /// `Float(start + i) + Float(c) * 0.25`.
    private func ramp(frames: Int, channels: Int, start: Int = 0) -> [Float] {
        var result = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                result[frame * channels + channel] =
                    Float(start + frame) + Float(channel) * 0.25
            }
        }
        return result
    }

    @discardableResult
    private func write(_ ring: OpaquePointer,
                       samples: [Float],
                       frames: UInt32) -> UInt32 {
        samples.withUnsafeBufferPointer {
            fr_sample_ring_write(ring, $0.baseAddress!, frames)
        }
    }

    private func read(_ ring: OpaquePointer,
                      frames: UInt32,
                      channels: Int) -> (count: UInt32, samples: [Float]) {
        var buffer = [Float](repeating: 0, count: Int(frames) * channels)
        let count = buffer.withUnsafeMutableBufferPointer {
            fr_sample_ring_read(ring, $0.baseAddress!, frames)
        }
        return (count, Array(buffer.prefix(Int(count) * channels)))
    }

    private func peek(_ ring: OpaquePointer,
                      offset: UInt32,
                      frames: UInt32,
                      channels: Int) -> (count: UInt32, samples: [Float]) {
        var buffer = [Float](repeating: 0, count: Int(frames) * channels)
        let count = buffer.withUnsafeMutableBufferPointer {
            fr_sample_ring_peek(ring, offset, $0.baseAddress!, frames)
        }
        return (count, Array(buffer.prefix(Int(count) * channels)))
    }

    // MARK: - Sample ring

    func testNewRingIsEmptyAndReportsConfiguration() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        XCTAssertEqual(fr_sample_ring_capacity(ring), 1_024)
        XCTAssertEqual(fr_sample_ring_available(ring), 0)
        XCTAssertEqual(fr_sample_ring_overflow_count(ring), 0)

        let result = read(ring, frames: 4, channels: 2)
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.samples.isEmpty)
    }

    func testWriteThenReadReturnsExactFrames() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        let input = ramp(frames: 128, channels: 2)
        XCTAssertEqual(write(ring, samples: input, frames: 128), 128)
        XCTAssertEqual(fr_sample_ring_available(ring), 128)

        let output = read(ring, frames: 128, channels: 2)
        XCTAssertEqual(output.count, 128)
        XCTAssertEqual(output.samples, input)
        XCTAssertEqual(fr_sample_ring_available(ring), 0)
    }

    func testReadLessThanAvailableLeavesRemainder() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        let input = ramp(frames: 100, channels: 2)
        write(ring, samples: input, frames: 100)

        let first = read(ring, frames: 30, channels: 2)
        XCTAssertEqual(first.count, 30)
        XCTAssertEqual(first.samples, Array(input.prefix(60)))
        XCTAssertEqual(fr_sample_ring_available(ring), 70)

        let rest = read(ring, frames: 100, channels: 2)
        XCTAssertEqual(rest.count, 70)
        XCTAssertEqual(rest.samples, Array(input.suffix(140)))
        XCTAssertEqual(fr_sample_ring_available(ring), 0)
    }

    func testWrapAroundPreservesOrder() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        let first = ramp(frames: 700, channels: 2, start: 0)
        write(ring, samples: first, frames: 700)
        XCTAssertEqual(read(ring, frames: 700, channels: 2).count, 700)

        // The second write starts at frame index 700 in the storage array and
        // must wrap at 1024 back to 0.
        let second = ramp(frames: 700, channels: 2, start: 700)
        XCTAssertEqual(write(ring, samples: second, frames: 700), 700)
        XCTAssertEqual(fr_sample_ring_available(ring), 700)

        let output = read(ring, frames: 700, channels: 2)
        XCTAssertEqual(output.count, 700)
        XCTAssertEqual(output.samples, second)
    }

    func testOverflowIsCountedAndPartialWritesReturnRoom() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        let full = ramp(frames: 1_024, channels: 2)
        XCTAssertEqual(write(ring, samples: full, frames: 1_024), 1_024)
        XCTAssertEqual(fr_sample_ring_overflow_count(ring), 0)

        // Completely full: no bytes accepted, one overflow event recorded.
        XCTAssertEqual(write(ring, samples: ramp(frames: 100, channels: 2), frames: 100), 0)
        XCTAssertEqual(fr_sample_ring_overflow_count(ring), 1)
        XCTAssertEqual(fr_sample_ring_available(ring), 1_024)

        // Free 100 frames, then ask for 200: exactly 100 are accepted and the
        // remainder is dropped without another overflow event.
        XCTAssertEqual(read(ring, frames: 100, channels: 2).count, 100)
        XCTAssertEqual(write(ring, samples: ramp(frames: 200, channels: 2), frames: 200), 100)
        XCTAssertEqual(fr_sample_ring_overflow_count(ring), 1)
        XCTAssertEqual(fr_sample_ring_available(ring), 1_024)

        XCTAssertEqual(write(ring, samples: ramp(frames: 1, channels: 2), frames: 1), 0)
        XCTAssertEqual(fr_sample_ring_overflow_count(ring), 2)
    }

    func testPeekDoesNotAdvanceAndHonoursOffset() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        let input = ramp(frames: 100, channels: 2)
        write(ring, samples: input, frames: 100)

        let at10 = peek(ring, offset: 10, frames: 5, channels: 2)
        XCTAssertEqual(at10.count, 5)
        XCTAssertEqual(at10.samples, Array(input[(10 * 2)..<(15 * 2)]))
        XCTAssertEqual(fr_sample_ring_available(ring), 100, "peek must not advance the read index")

        let head = read(ring, frames: 5, channels: 2)
        XCTAssertEqual(head.samples, Array(input[0..<10]))

        let next = peek(ring, offset: 0, frames: 5, channels: 2)
        XCTAssertEqual(next.samples, Array(input[10..<20]))

        // The read cursor is now at frame 5, so offset 90 starts at frame 95.
        // Requesting 10 frames yields the last 5 available frames.
        let tail = peek(ring, offset: 90, frames: 10, channels: 2)
        XCTAssertEqual(tail.count, 5)
        XCTAssertEqual(tail.samples, Array(input[(95 * 2)..<(100 * 2)]))

        // Offset at or beyond the write cursor yields nothing.
        XCTAssertEqual(peek(ring, offset: 95, frames: 1, channels: 2).count, 0)
        XCTAssertEqual(peek(ring, offset: 96, frames: 1, channels: 2).count, 0)
    }

    func testAdvanceClampsToAvailable() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        write(ring, samples: ramp(frames: 100, channels: 2), frames: 100)

        fr_sample_ring_advance(ring, 50)
        XCTAssertEqual(fr_sample_ring_available(ring), 50)
        XCTAssertEqual(peek(ring, offset: 0, frames: 1, channels: 2).samples.first, 50)

        // Advancing beyond the available count is clamped, not wrapped.
        fr_sample_ring_advance(ring, 1_000)
        XCTAssertEqual(fr_sample_ring_available(ring), 0)
        XCTAssertEqual(peek(ring, offset: 0, frames: 1, channels: 2).count, 0)
    }

    func testClearDiscardsUnreadFrames() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        write(ring, samples: ramp(frames: 64, channels: 2), frames: 64)
        XCTAssertEqual(fr_sample_ring_available(ring), 64)

        fr_sample_ring_clear(ring)
        XCTAssertEqual(fr_sample_ring_available(ring), 0)

        let fresh = ramp(frames: 8, channels: 2, start: 500)
        write(ring, samples: fresh, frames: 8)
        XCTAssertEqual(read(ring, frames: 8, channels: 2).samples, fresh)
    }

    func testStereoInterleavingIsPreserved() throws {
        let ring = try makeSampleRing(capacity: 1_024, channels: 2)
        defer { fr_sample_ring_destroy(ring) }

        var input = [Float](repeating: 0, count: 32 * 2)
        for frame in 0..<32 {
            input[frame * 2] = Float(frame) * 0.5
            input[frame * 2 + 1] = -Float(frame) * 0.25
        }
        write(ring, samples: input, frames: 32)
        let output = read(ring, frames: 32, channels: 2)

        for frame in 0..<32 {
            XCTAssertEqual(output.samples[frame * 2], Float(frame) * 0.5, accuracy: 1e-7)
            XCTAssertEqual(output.samples[frame * 2 + 1], -Float(frame) * 0.25, accuracy: 1e-7)
        }
    }

    func testZeroLengthCallsAreNoOps() throws {
        let ring = try makeSampleRing()
        defer { fr_sample_ring_destroy(ring) }

        XCTAssertEqual(write(ring, samples: ramp(frames: 4, channels: 2), frames: 0), 0)
        XCTAssertEqual(read(ring, frames: 0, channels: 2).count, 0)
        XCTAssertEqual(peek(ring, offset: 0, frames: 0, channels: 2).count, 0)
        XCTAssertEqual(fr_sample_ring_available(ring), 0)
    }

    func testSampleRingRejectsInvalidConfiguration() {
        XCTAssertNil(fr_sample_ring_create(1_023, 2), "capacity below 1024")
        XCTAssertNil(fr_sample_ring_create(1_024, 0), "zero channels")
        XCTAssertNil(fr_sample_ring_create(1_024, 9), "more than 8 channels")
        XCTAssertNil(fr_sample_ring_create(UInt32((1 << 22) + 1), 1), "capacity above 2^22")
    }

    // MARK: - Block ring

    func testBlockRingRoundTripPreservesMetadata() throws {
        let ring = try makeBlockRing(slots: 4, maxFrames: 256, channels: 2)
        defer { fr_block_ring_destroy(ring) }

        let input = ramp(frames: 128, channels: 2)
        let pushed = input.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 128, 2, 7, 12_345, 4.5)
        }
        XCTAssertEqual(pushed, 1)
        XCTAssertEqual(fr_block_ring_dropped(ring), 0)
        XCTAssertEqual(fr_block_ring_count(ring), 4)
        XCTAssertEqual(fr_block_ring_max_frames(ring), 256)
        XCTAssertEqual(fr_block_ring_channels(ring), 2)

        var output = [Float](repeating: 0, count: 256 * 2)
        var meta = FRBlockMeta()
        let popped = output.withUnsafeMutableBufferPointer {
            fr_block_ring_pop(ring, $0.baseAddress!, 256, &meta)
        }
        XCTAssertEqual(popped, 1)
        XCTAssertEqual(meta.frames, 128)
        XCTAssertEqual(meta.channels, 2)
        XCTAssertEqual(meta.timestamp_flags, 7)
        XCTAssertEqual(meta.host_time, 12_345)
        XCTAssertEqual(meta.sample_time, 4.5, accuracy: 1e-12)
        XCTAssertEqual(meta.sequence, 0)
        XCTAssertEqual(meta.dropped_before, 0)
        XCTAssertEqual(Array(output.prefix(256)), input)
    }

    func testBlockRingDropsWhenFullAndAcceptsAgainAfterPop() throws {
        let ring = try makeBlockRing(slots: 4, maxFrames: 256, channels: 2)
        defer { fr_block_ring_destroy(ring) }

        let input = ramp(frames: 64, channels: 2)
        for index in 0..<4 {
            let pushed = input.withUnsafeBufferPointer {
                fr_block_ring_push(ring, $0.baseAddress!, 64, 2, 1,
                                   UInt64(index), Double(index))
            }
            XCTAssertEqual(pushed, 1)
        }
        XCTAssertEqual(fr_block_ring_dropped(ring), 0)

        let rejected = input.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 64, 2, 1, 99, 99)
        }
        XCTAssertEqual(rejected, 0)
        XCTAssertEqual(fr_block_ring_dropped(ring), 1)

        var output = [Float](repeating: 0, count: 256 * 2)
        var meta = FRBlockMeta()
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            fr_block_ring_pop(ring, $0.baseAddress!, 256, &meta)
        }, 1)
        XCTAssertEqual(meta.host_time, 0)

        let accepted = input.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 64, 2, 1, 100, 100)
        }
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(fr_block_ring_dropped(ring), 1)
    }

    func testBlockRingRejectsChannelMismatchAndEmptyPush() throws {
        let ring = try makeBlockRing(slots: 4, maxFrames: 256, channels: 2)
        defer { fr_block_ring_destroy(ring) }

        let mono = [Float](repeating: 0, count: 64)
        let wrongChannels = mono.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 64, 1, 0, 0, 0)
        }
        XCTAssertEqual(wrongChannels, -1)

        let stereo = ramp(frames: 1, channels: 2)
        let empty = stereo.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 0, 2, 0, 0, 0)
        }
        XCTAssertEqual(empty, -1)
    }

    /// Current implementation truncates an oversized block to max_frames and
    /// reports success. This test pins that behaviour; see DEFECTS QA-002 for
    /// the silent-data-loss concern.
    func testBlockRingOversizedPushTruncatesToMaxFrames() throws {
        let ring = try makeBlockRing(slots: 2, maxFrames: 64, channels: 2)
        defer { fr_block_ring_destroy(ring) }

        let input = ramp(frames: 100, channels: 2)
        let pushed = input.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 100, 2, 0, 0, 0)
        }
        XCTAssertEqual(pushed, 1)

        var output = [Float](repeating: 0, count: 64 * 2)
        var meta = FRBlockMeta()
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            fr_block_ring_pop(ring, $0.baseAddress!, 64, &meta)
        }, 1)
        XCTAssertEqual(meta.frames, 64)
        XCTAssertEqual(Array(output), Array(input.prefix(128)))
    }

    func testBlockRingPopWithTooSmallBufferDoesNotAdvance() throws {
        let ring = try makeBlockRing(slots: 4, maxFrames: 256, channels: 2)
        defer { fr_block_ring_destroy(ring) }

        let input = ramp(frames: 128, channels: 2)
        _ = input.withUnsafeBufferPointer {
            fr_block_ring_push(ring, $0.baseAddress!, 128, 2, 0, 0, 0)
        }

        var small = [Float](repeating: 0, count: 64 * 2)
        var meta = FRBlockMeta()
        XCTAssertEqual(small.withUnsafeMutableBufferPointer {
            fr_block_ring_pop(ring, $0.baseAddress!, 64, &meta)
        }, -1)

        var full = [Float](repeating: 0, count: 256 * 2)
        XCTAssertEqual(full.withUnsafeMutableBufferPointer {
            fr_block_ring_pop(ring, $0.baseAddress!, 256, &meta)
        }, 1)
        XCTAssertEqual(meta.frames, 128)
    }

    func testBlockRingRejectsInvalidConfiguration() {
        XCTAssertNil(fr_block_ring_create(1, 256, 2), "slots below 2")
        XCTAssertNil(fr_block_ring_create(3, 256, 2), "slots must be power of two")
        XCTAssertNil(fr_block_ring_create(257, 256, 2), "slots above 256")
        XCTAssertNil(fr_block_ring_create(4, 63, 2), "max_frames below 64")
        XCTAssertNil(fr_block_ring_create(4, 16_385, 2), "max_frames above 16384")
        XCTAssertNil(fr_block_ring_create(4, 256, 0), "zero channels")
        XCTAssertNil(fr_block_ring_create(4, 256, 9), "more than 8 channels")
    }
}
