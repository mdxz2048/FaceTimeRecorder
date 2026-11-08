import Foundation
import AudioToolbox
import CoreAudio

public enum TonePlayerError: Error, CustomStringConvertible {
    case noComponent
    case status(String, OSStatus)
    case alreadyRunning

    public var description: String {
        switch self {
        case .noComponent: return "HAL output AudioUnit is unavailable"
        case let .status(operation, code):
            return "\(operation) failed: \(code) (\(CoreAudioError.fourCC(code)))"
        case .alreadyRunning: return "tone player already running"
        }
    }
}

private final class ToneState {
    var phase: Double = 0
    let delta: Double
    let amplitude: Float
    var framesRemaining: Int
    var fadeInFrames: Int
    var fadeOutFrames: Int
    var rendered: Int = 0

    init(frequency: Double, sampleRate: Double, amplitude: Float, frames: Int) {
        self.delta = 2 * Double.pi * frequency / sampleRate
        self.amplitude = amplitude
        self.framesRemaining = frames
        self.fadeInFrames = Int(sampleRate * 0.03)
        self.fadeOutFrames = Int(sampleRate * 0.03)
    }
}

private let toneRender: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard let first = buffers.first, let raw = first.mData else { return noErr }
    let state = Unmanaged<ToneState>.fromOpaque(refCon).takeUnretainedValue()
    let pointer = raw.assumingMemoryBound(to: Float.self)
    let count = Int(frames)
    let channels = Int(first.mNumberChannels)
    for frame in 0..<count {
        var gain = state.amplitude
        if state.rendered < state.fadeInFrames {
            gain *= Float(state.rendered) / Float(max(state.fadeInFrames, 1))
        }
        if state.framesRemaining <= state.fadeOutFrames {
            gain *= Float(max(state.framesRemaining, 0)) / Float(max(state.fadeOutFrames, 1))
        }
        let value = Float(sin(state.phase)) * gain
        state.phase += state.delta
        if state.phase > 2 * Double.pi { state.phase -= 2 * Double.pi }
        for channel in 0..<channels {
            pointer[frame * channels + channel] = value
        }
        state.rendered += 1
        state.framesRemaining = max(0, state.framesRemaining - 1)
    }
    return noErr
}

/// Plays a sine tone into a chosen output device through AUHAL. Used for the
/// capture-path self-test: HomePod Flow Audio is a sink, so a tone sent to it is
/// inaudible but still exercises the exact HAL render path FaceTime uses.
public final class TonePlayer: @unchecked Sendable {
    private var unit: AudioComponentInstance?
    private var state: ToneState?
    private var running = false
    private let lock = NSLock()

    public init() {}

    public func start(deviceUID: String,
                      frequency: Double = 1_000,
                      amplitude: Float = 0.1,
                      duration: TimeInterval = 1.0,
                      sampleRate: Double = 48_000) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw TonePlayerError.alreadyRunning }
        guard let device = AudioDeviceCatalog.deviceID(forUID: deviceUID) else {
            throw CoreAudioError.deviceNotFound(deviceUID)
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw TonePlayerError.noComponent
        }
        var created: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &created)
        guard status == noErr, let instance = created else {
            throw TonePlayerError.status("AudioComponentInstanceNew", status)
        }
        unit = instance
        defer { if !running { AudioComponentInstanceDispose(instance) } }

        var enable: UInt32 = 1
        status = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &enable, 4)
        guard status == noErr else { throw TonePlayerError.status("EnableIO(output)", status) }
        var deviceID = device
        status = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceID, 4)
        guard status == noErr else { throw TonePlayerError.status("CurrentDevice", status) }
        var format = AudioStreamBasicDescription.float32(sampleRate: sampleRate, channels: 2)
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &format,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw TonePlayerError.status("StreamFormat", status) }

        let totalFrames = max(1, Int(duration * sampleRate))
        let tone = ToneState(frequency: frequency, sampleRate: sampleRate,
                             amplitude: amplitude, frames: totalFrames)
        state = tone
        var callback = AURenderCallbackStruct(
            inputProc: toneRender,
            inputProcRefCon: Unmanaged.passUnretained(tone).toOpaque())
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw TonePlayerError.status("SetRenderCallback", status) }
        status = AudioUnitInitialize(instance)
        guard status == noErr else { throw TonePlayerError.status("AudioUnitInitialize", status) }
        status = AudioOutputUnitStart(instance)
        guard status == noErr else { throw TonePlayerError.status("AudioOutputUnitStart", status) }
        running = true
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Frames still scheduled; useful for a self-test that waits for the tone
    /// to finish before reading the measured RMS.
    public var framesRemaining: Int {
        lock.lock(); defer { lock.unlock() }
        return state?.framesRemaining ?? 0
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let unit else { return }
        if running { _ = AudioOutputUnitStop(unit) }
        _ = AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        state = nil
        running = false
    }

    deinit { stop() }
}
