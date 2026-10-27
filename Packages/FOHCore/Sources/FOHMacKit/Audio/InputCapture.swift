#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

struct AudioCaptureError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed (OSStatus \(status))" }
}

@inline(__always)
func checkAudio(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else { throw AudioCaptureError(status: status, context: context) }
}

/// Read-only capture of every input channel of one device through an AUHAL input unit.
/// The device keeps working normally for every other app (MainStage included).
final class InputCapture: @unchecked Sendable {
    let deviceID: AudioDeviceID
    let channels: Int
    let sampleRate: Double
    /// Called on the real-time audio thread with non-interleaved Float32 buffers (one per channel).
    var onBuffers: ((UnsafeMutableAudioBufferListPointer, Int) -> Void)?

    private var unit: AudioUnit?
    private let maxFrames: UInt32 = 4096
    private var buffers: UnsafeMutableAudioBufferListPointer

    init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioCaptureError(status: -1, context: "AUHAL lookup")
        }
        var instance: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(component, &instance), "AudioComponentInstanceNew")
        guard let unit = instance else { throw AudioCaptureError(status: -1, context: "AUHAL instance") }

        var one: UInt32 = 1, zero: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        do {
            try checkAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32), "Enable input")
            try checkAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32), "Disable output")
            var device = deviceID
            try checkAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)), "Set device")

            var hw = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checkAudio(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "Device format")
            let channelCount = Int(hw.mChannelsPerFrame)
            guard channelCount > 0 else { throw AudioCaptureError(status: -1, context: "Device has no input channels") }
            let rate = hw.mSampleRate > 0 ? hw.mSampleRate : HAL.nominalSampleRate(deviceID)

            var client = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channelCount),
                mBitsPerChannel: 32, mReserved: 0)
            try checkAudio(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "Client format")

            var frames = maxFrames
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, u32)

            channels = channelCount
            sampleRate = rate
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        buffers = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            buffers[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4,
                                     mData: UnsafeMutableRawPointer.allocate(byteCount: Int(maxFrames) * 4, alignment: 16))
        }
        self.unit = unit

        var callback = AURenderCallbackStruct(inputProc: inputRenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        do {
            try checkAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Input callback")
            try checkAudio(AudioUnitInitialize(unit), "AudioUnitInitialize")
        } catch {
            dispose()
            throw error
        }
    }

    deinit { dispose() }

    func start() throws {
        guard let unit else { return }
        try checkAudio(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
    }

    private func dispose() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            for b in buffers { b.mData?.deallocate() }
            free(buffers.unsafeMutablePointer)
        }
    }

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, frames <= maxFrames else { return noErr }
        for i in 0..<buffers.count { buffers[i].mDataByteSize = frames * 4 }
        let status = AudioUnitRender(unit, flags, time, bus, frames, buffers.unsafeMutablePointer)
        if status == noErr { onBuffers?(buffers, Int(frames)) }
        return status
    }
}

private let inputRenderCallback: AURenderCallback = { refCon, flags, time, bus, frames, _ in
    Unmanaged<InputCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
}
#endif
