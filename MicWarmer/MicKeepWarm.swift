import AVFoundation
import CoreAudio
import Foundation
import os

/// Holds the microphone hardware powered ("warm") so push-to-talk dictation activates instantly.
/// Every captured sample is discarded the instant it arrives — nothing is recorded, stored, or
/// transmitted.
///
/// **Warms every real input device, not just the system default.** Dictation apps are often pinned
/// to a *specific* mic (e.g. Wispr Flow → the built-in MacBook mic), while the *system default* can
/// be a different device (e.g. a Studio Display mic when docked). Warming only the default left the
/// app's actual mic cold, so the first words were still clipped when docked. We therefore warm every
/// built-in/wired input device and follow hot-plugging (dock/undock), so whichever mic the dictation
/// app uses is always warm. **Bluetooth** devices are skipped (warming one forces low-quality SCO
/// telephony mode), as are **virtual/aggregate** devices (no hardware to warm).
///
/// **Robustness:** macOS can quietly stop delivering audio while still reporting a session as
/// running (a permission glitch after an ad-hoc rebuild, sleep/wake, a device reconfig, or App Nap
/// throttling a background app). So we trust *real samples*, not `isRunning`: a device counts as
/// warm only once samples are confirmed flowing, a watchdog rebuilds any device that stalls, and we
/// hold a `.background` activity assertion so App Nap can't suspend us (without keeping the Mac
/// awake). Key transitions are logged via `os_log` (subsystem `com.edwin.MicWarmer`).
final class MicKeepWarm: NSObject {

    /// Called on the main thread when no mic can be kept capturing and the watchdog has given up, so
    /// the UI can drop the "warm" state instead of showing a stale/lying indicator.
    var onWarmthLost: (() -> Void)?

    private let log = Logger(subsystem: "com.edwin.MicWarmer", category: "keepwarm")

    // All session work is serialized here (startRunning/stopRunning block); samples are delivered
    // on a separate serial queue, as AVFoundation requires.
    private let sessionQueue = DispatchQueue(label: "com.edwin.MicWarmer.session")
    private let sampleQueue = DispatchQueue(label: "com.edwin.MicWarmer.samples")

    // One keep-warm session per device, keyed by the device's uniqueID.
    private var warmers: [String: DeviceWarmer] = [:]

    private var wantWarm = false
    private var watchdog: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var tickCount = 0
    private var allColdSince: TimeInterval = 0   // when EVERY device last went cold (0 = some warm)

    // Tuning (seconds). Samples normally arrive every few milliseconds, so a gap this large means a
    // device genuinely stopped capturing.
    private let stallGap: TimeInterval = 1.0
    private let buildGrace: TimeInterval = 1.5      // don't judge a session until samples can ramp up
    private let retryInterval: TimeInterval = 3.0   // min spacing between rebuilds of one device
    private let watchdogInterval: TimeInterval = 1.0
    private let reconcileEvery = 4                  // re-scan devices every Nth tick (dock/undock)
    private let confirmTimeout: TimeInterval = 2.5
    private let giveUpAfter: TimeInterval = 60.0    // give up only after this long with zero audio

    /// Warms every real input mic. `completion(true)` is called on the main thread once at least one
    /// device is confirmed actually delivering audio; `false` means there are no input devices or
    /// macOS is delivering nothing from any of them (almost always a blocked microphone permission).
    func start(completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            self.wantWarm = true
            self.beginActivity()
            self.reconcileDevices()
            guard !self.warmers.isEmpty else {
                self.wantWarm = false
                self.endActivity()
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.confirmAnyCapturing { ok in
                if ok {
                    self.allColdSince = 0
                    self.log.notice("warming \(self.warmers.count, privacy: .public) input device(s)")
                    self.startWatchdog()
                } else {
                    self.wantWarm = false
                    self.teardownAll()
                    self.endActivity()
                    self.log.error("warm failed — no audio from any device (mic likely blocked)")
                }
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    /// Releases all mics, returning the Mac to its default behavior (mics sleep after idle).
    func stop() {
        sessionQueue.async {
            self.wantWarm = false
            self.stopWatchdog()
            self.teardownAll()
            self.endActivity()
            self.log.notice("mic released by user")
        }
    }

    // MARK: - App Nap exemption

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(options: .background,
                                                              reason: "Keeping the microphone warm")
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - Device set (always on sessionQueue)

    // Brings `warmers` in line with the devices currently worth warming: adds a fresh session for
    // any new device (e.g. a Studio Display just docked) and drops sessions for devices that vanished.
    private func reconcileDevices() {
        let wanted = warmableDevices()
        let wantedUIDs = Set(wanted.map { $0.uniqueID })

        for (uid, warmer) in warmers where !wantedUIDs.contains(uid) {
            warmer.teardown()
            warmers[uid] = nil
            log.notice("stopped warming removed device \(warmer.name, privacy: .public)")
        }
        for device in wanted where warmers[device.uniqueID] == nil {
            let warmer = DeviceWarmer(device: device, sampleQueue: sampleQueue)
            if warmer.build() {
                warmers[device.uniqueID] = warmer
                log.notice("warming \(device.localizedName, privacy: .public)")
            }
        }
    }

    private func teardownAll() {
        for (_, warmer) in warmers { warmer.teardown() }
        warmers.removeAll()
    }

    // Every audio input device except Bluetooth (warming it forces low-quality SCO) and
    // virtual/aggregate devices (no hardware to keep awake).
    private func warmableDevices() -> [AVCaptureDevice] {
        let skip = skipUIDs()
        return AVCaptureDevice.devices(for: .audio).filter { !skip.contains($0.uniqueID) }
    }

    // MARK: - Confirming real capture

    // Polls (on sessionQueue, non-blocking) until at least one device delivers a real sample, so we
    // only claim "warm" once audio is genuinely flowing — catching a silently-blocked mic.
    private func confirmAnyCapturing(_ done: @escaping (Bool) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + confirmTimeout
        func poll() {
            if !self.wantWarm { done(false); return }
            if self.warmers.values.contains(where: { $0.hasSample() }) { done(true); return }
            if ProcessInfo.processInfo.systemUptime > deadline { done(false); return }
            self.sessionQueue.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    // MARK: - Watchdog (handler runs on sessionQueue)

    private func startWatchdog() {
        stopWatchdog()
        tickCount = 0
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        guard wantWarm else { return }
        let now = ProcessInfo.processInfo.systemUptime
        tickCount += 1
        if tickCount % reconcileEvery == 0 { reconcileDevices() }   // pick up dock/undock

        var anyWarm = false
        for (_, warmer) in warmers {
            let age = now - warmer.builtAt
            if age < buildGrace { anyWarm = true; continue }              // just (re)built — give it time
            if warmer.secondsSinceSample(now) <= stallGap { anyWarm = true; continue }   // flowing
            if age >= retryInterval {                                     // stalled — rebuild (spaced out)
                log.notice("rebuilding \(warmer.name, privacy: .public) — audio stalled")
                warmer.build()
            }
        }

        if anyWarm { allColdSince = 0; return }

        // Nothing is delivering audio anywhere. Keep retrying, but eventually stop pretending warm.
        if allColdSince == 0 { allColdSince = now }
        if now - allColdSince > giveUpAfter {
            log.error("no audio from any mic for \(Int(self.giveUpAfter), privacy: .public)s — giving up")
            wantWarm = false
            stopWatchdog()
            teardownAll()
            endActivity()
            DispatchQueue.main.async { self.onWarmthLost?() }
        }
    }

    // MARK: - HAL helpers (which devices to skip)

    // UIDs of Bluetooth and virtual/aggregate devices, which we never warm.
    private func skipUIDs() -> Set<String> {
        let skipTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
        ]
        var skip = Set<String>()
        for device in halDeviceIDs() where skipTransports.contains(halUInt32(device, kAudioDevicePropertyTransportType)) {
            let uid = halUID(device)
            if !uid.isEmpty { skip.insert(uid) }
        }
        return skip
    }

    private func halDeviceIDs() -> [AudioDeviceID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if !ids.isEmpty { AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) }
        return ids
    }

    private func halUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value
    }

    private func halUID(_ device: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        if status == noErr, let unmanaged { return unmanaged.takeRetainedValue() as String }
        return ""
    }
}

/// One held-open capture session for a single device. The delegate discards every sample but
/// timestamps its arrival, which is the proof that this device is genuinely capturing.
private final class DeviceWarmer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let name: String
    private let device: AVCaptureDevice
    private let sampleQueue: DispatchQueue
    private var session: AVCaptureSession?

    private let lock = NSLock()
    private var lastSampleAt: TimeInterval = 0
    private(set) var builtAt: TimeInterval = 0

    init(device: AVCaptureDevice, sampleQueue: DispatchQueue) {
        self.device = device
        self.name = device.localizedName
        self.sampleQueue = sampleQueue
    }

    // Tears down any existing session and builds + starts a fresh one. Returns whether it started.
    @discardableResult
    func build() -> Bool {
        teardown()
        let newSession = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            newSession.beginConfiguration()
            guard newSession.canAddInput(input), newSession.canAddOutput(output) else {
                newSession.commitConfiguration()
                return false
            }
            newSession.addInput(input)
            newSession.addOutput(output)
            newSession.commitConfiguration()
        } catch {
            return false
        }
        setLastSample(0)
        builtAt = ProcessInfo.processInfo.systemUptime
        newSession.startRunning()
        session = newSession
        return newSession.isRunning
    }

    func teardown() {
        if let session, session.isRunning { session.stopRunning() }
        session = nil
    }

    // Intentionally discards the audio; only records that a sample arrived. Not retaining the buffer
    // means ARC releases it immediately — nothing is ever recorded or stored.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        setLastSample(ProcessInfo.processInfo.systemUptime)
    }

    private func setLastSample(_ time: TimeInterval) {
        lock.lock(); lastSampleAt = time; lock.unlock()
    }

    func hasSample() -> Bool {
        lock.lock(); let t = lastSampleAt; lock.unlock()
        return t != 0
    }

    func secondsSinceSample(_ now: TimeInterval) -> TimeInterval {
        lock.lock(); let t = lastSampleAt; lock.unlock()
        return t == 0 ? .greatestFiniteMagnitude : now - t
    }
}
