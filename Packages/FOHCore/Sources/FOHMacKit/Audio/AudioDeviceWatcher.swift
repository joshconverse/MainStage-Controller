#if os(macOS)
import CoreAudio
import Foundation

/// Calls `onChange` on `queue`, debounced, when an audio device is added or removed or the system default input
/// changes: an interface plugged in or unplugged. Listens to the Core Audio HAL until `stop()` or release.
final class AudioDeviceWatcher: @unchecked Sendable {
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private let lock = NSLock()
    private var listener: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?

    init(queue: DispatchQueue, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
        for selector in Self.selectors {
            var addr = HAL.address(selector)
            AudioObjectAddPropertyListenerBlock(HAL.system, &addr, queue, block)
        }
        listener = block
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let block = listener
        listener = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
        guard let block else { return }
        for selector in Self.selectors {
            var addr = HAL.address(selector)
            AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, queue, block)
        }
    }

    /// A plug-in usually fires several notifications (device list, then default input); act once they settle.
    private func schedule() {
        lock.lock()
        defer { lock.unlock() }
        guard listener != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
#endif
