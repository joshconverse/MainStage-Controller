#if os(macOS)
import Foundation
import FOHCore

// Meters and RTA (PLAN.md §2.5): the MeterSource reads the audio interface inputs and taps MainStage's output, and
// FOH Meter plugins inside MainStage send their strips' levels over UDP; the bridge forwards frames to connected
// clients at ≤25 Hz and the RTA to whichever client asked for it.
extension BridgeServer {
    func startMeters() {
        guard options.enableMeters, meterSource == nil else { return }
        startPluginMeters()
        let source = options.meterSourceFactory()
        source.onFrame = { [weak self] frame in
            DispatchQueue.main.async {
                self?.latestFrame = frame
                self?.frameDirty = true
            }
        }
        source.onRTA = { [weak self] channels, bands in
            DispatchQueue.main.async { self?.forwardRTA(channels: channels, bands: bands) }
        }
        meterSource = source
        source.start(inputDeviceUID: inputDeviceUID, log: { [weak self] line in
            DispatchQueue.main.async { self?.log(line.hasPrefix("Meters") ? line : "Meters: \(line)") }
        })
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.flushMeters() }
        RunLoop.main.add(timer, forMode: .common)   // meters keep flowing while a menu or alert is open
        meterTimer = timer
        // An interface plugged in or unplugged: refresh the menu's device list and the status straight away
        // (the meter source reopens or closes its capture on its own watcher).
        deviceWatcher = AudioDeviceWatcher(queue: .main, debounce: 0.6) { [weak self] in
            self?.refreshInputDevices()
            self?.refreshMeterStatus()
        }
        refreshInputDevicesNow()
        refreshMeterStatus()
    }

    func stopMeters() {
        pluginMeterReceiver?.stop()
        pluginMeterReceiver = nil
        pluginMeterBank = PluginMeterBank()
        meterTimer?.invalidate()
        meterTimer = nil
        deviceWatcher?.stop()
        deviceWatcher = nil
        meterSource?.stop()
        meterSource = nil
    }

    /// Send the latest frame if it changed and anyone is listening (≤25 Hz, coalesced).
    private func flushMeters() {
        let strips = pluginMeterBank.levels(now: ProcessInfo.processInfo.systemUptime)
        let live = show.strips.filter { strips[$0.id] != nil }.map(\.name)
        if (status.pluginMeters ?? []) != live {
            status.pluginMeters = live.isEmpty ? nil : live
            frameDirty = true   // a meter that went away is cleared on the iPad
            refreshStatus(broadcast: true)
        }
        guard frameDirty else { return }
        frameDirty = false
        guard !connections.isEmpty else { return }
        var frame = latestFrame ?? MeterFrame()
        frame.strips = strips
        broadcast(.message(OSCMessage(FOHProtocol.Path.meters, [.blob(frame.encoded())])))
    }

    // MARK: FOH Meter plugin

    private func startPluginMeters() {
        guard let port = options.pluginMeterPort, pluginMeterReceiver == nil else { return }
        do {
            pluginMeterReceiver = try PluginMeterReceiver(port: port, queue: .main) { [weak self] packet in
                self?.receivePluginMeter(packet)
            }
            log("FOH Meter plugin: listening on 127.0.0.1 UDP \(port)")
        } catch {
            log("⚠︎ FOH Meter plugin: can't listen — \(error)")
        }
    }

    /// Main thread (the receiver's queue).
    func receivePluginMeter(_ packet: PluginMeterPacket) {
        let strip = show.stripForPluginMeter(contextName: packet.contextName)
        pluginMeterBank.add(packet, stripKey: strip?.id, now: ProcessInfo.processInfo.systemUptime)
        frameDirty = true
        let resolution = strip.map { "→ \($0.name) (\(packet.peak.count) ch)" }
            ?? "matches no strip: give the FOH strip or the MainStage channel strip that name"
        if pluginMeterLogged[packet.contextName] != resolution {
            pluginMeterLogged[packet.contextName] = resolution
            log("FOH Meter on \"\(packet.contextName)\" \(resolution)")
        }
    }

    /// One RTA stream at a time: the most recent subscriber's strip. Other subscribers to the same strip get it too.
    func updateRTASubscriptions() {
        rtaOrder.removeAll { connections[$0]?.rtaStrip == nil }
        let active = rtaOrder.last.flatMap { connections[$0]?.rtaStrip }
        guard active != rtaActiveStrip else { return }
        rtaActiveStrip = active
        let channels = active.flatMap { StripRef(key: $0) }.flatMap { show.strip($0) }?.hardwareInputChannels ?? []
        meterSource?.setRTAChannels(channels)
        log(active.map { "RTA → \($0) (inputs \(channels.map { $0 + 1 }))" } ?? "RTA off")
    }

    private func forwardRTA(channels: [Int], bands: [UInt8]) {
        guard let key = rtaActiveStrip else { return }
        let message = RTAFrame(strip: key, bands: bands).message()
        for conn in connections.values where conn.rtaStrip == key { conn.send(message) }
    }

    /// Name of the chosen device as last seen connected, so "waiting for Scarlett 2i2 USB" can be shown while
    /// it's unplugged. Persisted beside the UID.
    static let inputDeviceNameKey = "foh.audio.inputDeviceName"

    var savedInputDeviceName: String? {
        MIDIEngine.sharedDefaults.string(forKey: Self.inputDeviceNameKey + options.portNameSuffix)
    }

    /// Choose the audio device the input meters read (nil = system default). Persisted. While the chosen device
    /// is unplugged the meters read nothing and the status says what they're waiting for.
    public func setInputDevice(uid: String?) {
        inputDeviceUID = uid
        let key = Self.inputDeviceKey + options.portNameSuffix
        if let uid { MIDIEngine.sharedDefaults.set(uid, forKey: key) } else { MIDIEngine.sharedDefaults.removeObject(forKey: key) }
        rememberInputDeviceName()
        guard let source = meterSource else { return }
        source.stop()
        source.start(inputDeviceUID: uid, log: { [weak self] line in
            DispatchQueue.main.async { self?.log(line.hasPrefix("Meters") ? line : "Meters: \(line)") }
        })
        if let strip = rtaActiveStrip.flatMap({ StripRef(key: $0) }).flatMap({ show.strip($0) }) {
            source.setRTAChannels(strip.hardwareInputChannels)
        }
        log("Meter input → \(uid ?? "system default")")
        refreshMeterStatus()
    }

    /// Enumerated off the main thread: Core Audio can be slow during a hot-plug, and main also routes OSC → MIDI.
    public func refreshInputDevices() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = AudioMetering.listInputDevices()
            DispatchQueue.main.async {
                self?.applyInputDevices(devices)
                self?.refreshMeterStatus()
            }
        }
    }

    /// The same, synchronously (launch, tests).
    func refreshInputDevicesNow() {
        applyInputDevices(AudioMetering.listInputDevices())
    }

    private func applyInputDevices(_ devices: [AudioInputDevice]) {
        if devices != inputDevices { inputDevices = devices }
        rememberInputDeviceName()
    }

    private func rememberInputDeviceName() {
        let key = Self.inputDeviceNameKey + options.portNameSuffix
        guard let uid = inputDeviceUID else { return MIDIEngine.sharedDefaults.removeObject(forKey: key) }
        if let name = inputDevices.first(where: { $0.uid == uid })?.name, name != savedInputDeviceName {
            MIDIEngine.sharedDefaults.set(name, forKey: key)
        }
    }

    /// The chosen device's name while it's unplugged (meters running, nothing open, device not connected).
    var inputWaitingFor: String? {
        guard meterSource != nil, meterSource?.inputDeviceName == nil, let uid = inputDeviceUID,
              case .waiting = InputDevicePolicy.decide(chosenUID: uid, connected: inputDevices.map(\.uid), defaultUID: nil)
        else { return nil }
        return savedInputDeviceName ?? uid
    }

    func refreshMeterStatus() {
        let device = meterSource?.inputDeviceName
        let channels = meterSource?.inputChannelCount
        let waiting = inputWaitingFor
        let tap = meterSource?.outputTapName
        var changed = false
        if status.inputDevice != device { status.inputDevice = device; changed = true }
        if status.inputChannelCount != channels { status.inputChannelCount = channels; changed = true }
        if status.inputWaitingFor != waiting { status.inputWaitingFor = waiting; changed = true }
        if status.outputTap != tap { status.outputTap = tap; changed = true }
        if changed { refreshStatus(broadcast: true) }
    }
}
#endif
