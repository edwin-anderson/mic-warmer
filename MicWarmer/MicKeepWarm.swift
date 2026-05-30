import AVFoundation
import Foundation

/// Holds an audio capture session open so the microphone hardware stays powered ("warm"), which is
/// what makes push-to-talk dictation activate instantly. Every captured sample is discarded the
/// instant it arrives — nothing is recorded, stored, or transmitted.
///
/// Why this is more than "just call startRunning()": macOS can quietly stop delivering audio while
/// still reporting the session as running. A rebuild/reinstall can invalidate the microphone
/// permission (ad-hoc signing changes the code hash, so the old TCC grant no longer matches); sleep
/// /wake tears the audio path down; another app can reconfigure the device. In all of these cases
/// `session.isRunning` typically stays `true` even though **zero audio is flowing** — so a naive
/// implementation would believe it's warm (orange icon on) while the mic is actually cold and
/// dictation is still clipped. That is exactly the bug this class exists to prevent.
///
/// So we trust *real samples*, not the running flag:
///   • `start` only reports success once audio is confirmed to be actually flowing.
///   • A watchdog rebuilds a fresh session if samples ever stop, keeping the mic genuinely warm
///     across sleep/wake and device hiccups.
///   • If it can't get audio back, it tells the app (`onWarmthLost`) so the UI stops claiming warm.
final class MicKeepWarm: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Called on the main thread when the mic stops capturing and the watchdog can't recover it,
    /// so the UI can drop the "warm" state instead of showing a stale/lying indicator.
    var onWarmthLost: (() -> Void)?

    // Rebuilt fresh on every warm so a previously-wedged session can never be silently reused.
    private var session: AVCaptureSession?

    // `startRunning()`/`stopRunning()` block, so all session work happens on this serial queue.
    private let sessionQueue = DispatchQueue(label: "com.edwin.MicWarmer.session")
    // AVFoundation requires sample-buffer delivery on a serial queue (and not the main queue).
    private let sampleQueue = DispatchQueue(label: "com.edwin.MicWarmer.samples")

    // The truth signal: monotonic timestamp (seconds since boot) of the most recent *real* sample.
    // 0 means "no sample has arrived since the current session was built". Written on `sampleQueue`,
    // read on `sessionQueue`, so it's guarded by a lock.
    private let sampleLock = NSLock()
    private var lastSampleAt: TimeInterval = 0
    private var lastBuildAt: TimeInterval = 0

    private var wantWarm = false              // does the user currently want the mic held warm?
    private var watchdog: DispatchSourceTimer?
    private var recoveryStrikes = 0

    // Watchdog tuning (seconds). Samples normally arrive every few milliseconds, so a gap as large
    // as `stallGap` unambiguously means the mic stopped capturing.
    private let stallGap: TimeInterval = 1.0
    private let buildGrace: TimeInterval = 1.5   // don't judge a session until samples can ramp up
    private let watchdogInterval: TimeInterval = 1.0
    private let confirmTimeout: TimeInterval = 2.0
    private let maxStrikes = 3                    // give up after this many failed recovery attempts

    /// Warms the mic. `completion(true)` is called on the main thread only once real audio samples
    /// are confirmed flowing. `completion(false)` means there's no input device, the session
    /// couldn't be built, or macOS started the session but is delivering nothing (almost always a
    /// blocked microphone permission).
    func start(completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            self.wantWarm = true
            guard self.buildAndStartSession() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.confirmCapturing { ok in
                if ok { self.startWatchdog() }
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    /// Releases the mic, returning the Mac to its default behavior (mic sleeps after idle).
    func stop() {
        sessionQueue.async {
            self.wantWarm = false
            self.stopWatchdog()
            self.teardownSession()
        }
    }

    // MARK: - Session build / teardown (always on sessionQueue)

    // Tears down any existing session and builds + starts a brand-new one: the default audio input
    // feeding a data output whose delegate discards every sample. Returns whether it started.
    private func buildAndStartSession() -> Bool {
        teardownSession()
        guard let device = AVCaptureDevice.default(for: .audio) else { return false }
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

        setLastSample(0)                                       // forget samples from any old session
        lastBuildAt = ProcessInfo.processInfo.systemUptime
        newSession.startRunning()
        session = newSession
        return newSession.isRunning
    }

    private func teardownSession() {
        if let session, session.isRunning { session.stopRunning() }
        session = nil
    }

    // MARK: - Truth signal: are real samples actually arriving?

    // Intentionally discards the audio. We only record that a sample arrived (proof the mic is
    // genuinely capturing); not retaining the buffer means ARC releases it immediately, so nothing
    // is ever recorded or stored.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        setLastSample(ProcessInfo.processInfo.systemUptime)
    }

    private func setLastSample(_ time: TimeInterval) {
        sampleLock.lock(); lastSampleAt = time; sampleLock.unlock()
    }

    private func hasSampleSinceBuild() -> Bool {
        sampleLock.lock(); let t = lastSampleAt; sampleLock.unlock()
        return t != 0
    }

    private func secondsSinceSample(_ now: TimeInterval) -> TimeInterval {
        sampleLock.lock(); let t = lastSampleAt; sampleLock.unlock()
        return t == 0 ? .greatestFiniteMagnitude : now - t
    }

    // Polls (on sessionQueue, non-blocking) for the first real sample after a start, so we only
    // claim "warm" once audio is truly flowing — catching the silent-denial case where the session
    // runs but no audio is delivered.
    private func confirmCapturing(_ done: @escaping (Bool) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + confirmTimeout
        func poll() {
            if !self.wantWarm { done(false); return }            // user turned it off mid-confirm
            if self.hasSampleSinceBuild() { done(true); return }  // real audio arrived → genuinely warm
            if ProcessInfo.processInfo.systemUptime > deadline { done(false); return }
            self.sessionQueue.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    // MARK: - Watchdog: keep the mic genuinely warm (handler runs on sessionQueue)

    private func startWatchdog() {
        stopWatchdog()
        recoveryStrikes = 0
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
        if now - lastBuildAt < buildGrace { return }     // just (re)built — let samples ramp up first
        if secondsSinceSample(now) <= stallGap {         // audio still flowing — all good
            recoveryStrikes = 0
            return
        }

        // Samples stopped: the mic went cold while we were supposed to be warm (sleep/wake, a
        // permission change, device reconfig…). Rebuild a fresh session to get audio back.
        recoveryStrikes += 1
        if recoveryStrikes >= maxStrikes {
            // Can't recover — stop pretending it's warm and let the UI reflect reality.
            wantWarm = false
            stopWatchdog()
            teardownSession()
            DispatchQueue.main.async { self.onWarmthLost?() }
            return
        }
        _ = buildAndStartSession()   // fresh session; samples should resume before the next ticks
    }
}
