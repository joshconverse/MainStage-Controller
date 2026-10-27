#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

/// Listens to one process's audio output through Core Audio process taps (macOS 14.2+):
/// tap(s) → private aggregate device → IOProc.
///
/// - Per-channel (`OutputTapPlan.Mode.perChannel`): one tap per output stream of the planned device, in stream
///   order, so buffer channel *n* is the device's output channel *n* — MainStage's "Out 3-4" meters as channels 2, 3.
/// - Mixdown: one stereo tap of everything the process plays (the fallback).
@available(macOS 14.2, *)
final class ProcessTapCapture: @unchecked Sendable {
    let pid: pid_t
    let plan: OutputTapPlan
    private(set) var channels = 2
    private(set) var sampleRate: Double = 48_000
    /// Called on the tap's IO queue with the tapped buffers.
    var onBuffers: ((UnsafeMutableAudioBufferListPointer, Int) -> Void)?

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "io.itstudios.foh.tap.io", qos: .userInteractive)

    init(pid: pid_t, plan: OutputTapPlan) throws {
        self.pid = pid
        self.plan = plan
        let process = try Self.processObject(for: pid)

        do {
            let descriptions = try Self.descriptions(for: plan, process: process)
            var tapUIDs: [String] = []
            var totalChannels = 0
            for description in descriptions {
                description.uuid = UUID()
                description.name = "FOH Bridge meters"
                description.isPrivate = true
                description.muteBehavior = .unmuted
                var tapID = AudioObjectID(kAudioObjectUnknown)
                try checkAudio(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
                tapIDs.append(tapID)
                guard let uid = HAL.string(tapID, kAudioTapPropertyUID) else {
                    throw AudioCaptureError(status: -1, context: "Tap UID")
                }
                tapUIDs.append(uid)
                let format: AudioStreamBasicDescription = HAL.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
                totalChannels += Int(format.mChannelsPerFrame)
                if format.mSampleRate > 0 { sampleRate = format.mSampleRate }
            }
            if totalChannels > 0 { channels = totalChannels }

            var aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "FOH Bridge Tap",
                kAudioAggregateDeviceUIDKey: AudioDevices.privateTapPrefix + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: tapUIDs.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] },
            ]
            // Clock the aggregate from the tapped device (per-channel) or the system output (mixdown).
            let clockUID = plan.mode == .perChannel ? plan.deviceUID : HAL.uid(HAL.defaultOutputDevice())
            if let clockUID {
                aggregate[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
                aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
            }
            try checkAudio(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")

            try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
                guard let self else { return }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, first.mNumberChannels > 0 else { return }
                let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
                self.onBuffers?(list, frames)
            }, "AudioDeviceCreateIOProcIDWithBlock")
        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    /// One description per stream for a per-channel plan; a single stereo mixdown otherwise.
    static func descriptions(for plan: OutputTapPlan, process: AudioObjectID) throws -> [CATapDescription] {
        switch plan.mode {
        case .mixdown:
            return [CATapDescription(stereoMixdownOfProcesses: [process])]
        case .perChannel:
            guard let uid = plan.deviceUID, !plan.streams.isEmpty else {
                throw AudioCaptureError(status: -1, context: "Per-channel tap needs a device with output streams")
            }
            return plan.streams.indices.map { CATapDescription(processes: [process], deviceUID: uid, stream: UInt($0)) }
        }
    }

    func start() throws {
        try checkAudio(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart (tap)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID { AudioDeviceStop(aggregateID, procID) }
    }

    private func teardown() {
        stop()
        if aggregateID != kAudioObjectUnknown {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        tapIDs.removeAll()
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var addr = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkAudio(AudioObjectGetPropertyData(HAL.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                       "Translate pid \(pid) to audio process")
        guard object != kAudioObjectUnknown else {
            throw AudioCaptureError(status: -1, context: "Process \(pid) has no Core Audio client yet")
        }
        return object
    }

    /// Per-channel when the plan asks for it, falling back to the stereo mixdown if that can't be created.
    /// Returns the capture plus the per-channel error (if the fallback was used).
    static func make(pid: pid_t, plan: OutputTapPlan) throws -> (ProcessTapCapture, fallbackFrom: Error?) {
        guard plan.mode == .perChannel else { return (try ProcessTapCapture(pid: pid, plan: plan), nil) }
        do {
            return (try ProcessTapCapture(pid: pid, plan: plan), nil)
        } catch {
            let mixdown = plan.asMixdown(reason: "per-channel tap failed (\(error))")
            return (try ProcessTapCapture(pid: pid, plan: mixdown), error)
        }
    }
}
#endif
