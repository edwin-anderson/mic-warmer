import AVFoundation

/// Holds an audio capture session open so the microphone hardware stays powered ("warm"),
/// which is what makes push-to-talk dictation activate instantly. Every captured sample is
/// discarded the instant it arrives — nothing is recorded, stored, or transmitted. The only
/// effect is that the mic stays awake (and macOS shows its orange indicator dot) until `stop()`.
final class MicKeepWarm: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()

    // `startRunning()`/`stopRunning()` block until the session settles, so they must run off the
    // main thread. A dedicated serial queue also serializes start/stop against each other.
    private let sessionQueue = DispatchQueue(label: "com.edwin.MicWarmer.session")
    // AVFoundation requires sample-buffer delivery on a serial queue (and not the main queue).
    private let sampleQueue = DispatchQueue(label: "com.edwin.MicWarmer.samples")

    private var configured = false

    /// Warms the mic. `completion` is always called on the main thread with whether the mic is
    /// now actually running (false if there's no audio device or the session couldn't be built).
    func start(completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            guard self.configureIfNeeded() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async { completion(running) }
        }
    }

    /// Releases the session, returning the Mac to its default behavior (mic sleeps after idle).
    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // Built once and reused: the default audio input feeding a data output whose delegate discards
    // everything. The output is what makes AVFoundation actively pull (and thus keep awake) the
    // hardware and light the orange indicator.
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(for: .audio) else { return false }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sampleQueue)

            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(output) else { return false }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            return false
        }

        configured = true
        return true
    }

    // Intentionally empty: captured audio is discarded immediately. Not retaining the sample
    // buffer means ARC releases it the moment this returns — nothing is ever recorded or stored.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}
}
