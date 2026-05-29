import AVFoundation
import CoreGraphics

/// All sound is synthesised at runtime with `AVAudioEngine` — no audio files to
/// bundle. One player node fires percussive one-shots (bounce / kick); a second
/// loops filtered noise whose volume tracks rolling speed.
///
/// Everything degrades gracefully: if the engine can't start (headless/CI), the
/// public methods become no-ops. Use only from the main thread.
final class SoundEngine {

    private let engine = AVAudioEngine()
    private let oneShot = AVAudioPlayerNode()
    private let roller = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 44_100, channels: 1, interleaved: false)!

    private var ready = false
    private var rollBuffer: AVAudioPCMBuffer?
    private var smoothedRoll: Float = 0
    private var rng: UInt32 = 0x9E3779B9

    /// Debounce: absolute time of the last bounce playback, so rapidly consecutive
    /// bounces don't queue an unbounded number of buffers in the oneShot node.
    private var lastBounceAt: CFTimeInterval = 0
    private let bounceDebounce: CFTimeInterval = 0.05   // 50 ms

    /// User-facing on/off. Handled entirely inside `setRollSpeed` to avoid races
    /// between the didSet and the per-frame volume update.
    var isEnabled = true

    private var configObserver: Any?

    func start() {
        attachAndStart()

        // Observe audio route changes (headphone unplug, Bluetooth, USB DAC, sleep/wake).
        // AVAudioEngine tears down its render graph and stops; we must restart it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in self?.restartEngine() }
    }

    func stop() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        engine.stop()
        ready = false
    }

    private func attachAndStart() {
        // Only attach nodes if they aren't already wired (idempotent restart).
        if !engine.attachedNodes.contains(oneShot) {
            engine.attach(oneShot)
            engine.attach(roller)
            engine.connect(oneShot, to: engine.mainMixerNode, format: format)
            engine.connect(roller, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        do {
            try engine.start()
            ready = true
        } catch {
            ready = false
            return
        }
        rollBuffer = makeNoiseLoop(duration: 1.0)
        oneShot.play()
        roller.volume = 0
        if let rb = rollBuffer {
            roller.scheduleBuffer(rb, at: nil, options: .loops, completionHandler: nil)
            roller.play()
        }
    }

    private func restartEngine() {
        guard !engine.isRunning else { return }
        engine.stop()
        attachAndStart()
    }

    // MARK: - One-shots

    /// A bouncy "thock" on landing. Pitch dips and gets louder with impact speed.
    /// Debounced: if called again within 50 ms the second bounce is dropped, so
    /// rapid floor+wall contact doesn't queue an unbounded number of buffers.
    func playBounce(impact: CGFloat) {
        guard ready, isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastBounceAt >= bounceDebounce else { return }
        lastBounceAt = now
        let norm = min(1, Float(impact) / 2600)
        let freq: Float = 320 - 70 * norm            // harder hit → a touch lower
        let amp: Float = 0.12 + 0.30 * norm
        let buf = makeTone(freq: freq, duration: 0.14, amplitude: amp,
                           secondHarmonic: 0.35, noiseMix: 0.10, decay: 26)
        schedule(buf)
    }

    /// A bright "pock" when the cursor kicks the ball.
    func playKick(strength: CGFloat) {
        guard ready, isEnabled else { return }
        let norm = min(1, Float(strength) / 2500)
        let freq: Float = 540 + 220 * norm
        let amp: Float = 0.16 + 0.26 * norm
        let buf = makeTone(freq: freq, duration: 0.10, amplitude: amp,
                           secondHarmonic: 0.5, noiseMix: 0.28, decay: 40)
        schedule(buf)
    }

    // MARK: - Continuous roll

    /// Feed the rolling speed (pt/s) each frame; volume follows it, smoothed.
    /// When `isEnabled` is false, volume is driven to zero and stays there —
    /// no race with a didSet because all volume writes happen here.
    func setRollSpeed(_ speed: CGFloat) {
        guard ready else { return }
        let target: Float = isEnabled ? min(0.22, Float(speed) / 5_000) : 0
        let prev = smoothedRoll
        smoothedRoll += (target - smoothedRoll) * 0.15
        // Skip the IPC write when the change is imperceptible (~every frame otherwise).
        if abs(smoothedRoll - prev) > 0.001 || (prev > 0.001 && smoothedRoll <= 0.001) {
            roller.volume = smoothedRoll
        }
    }

    // MARK: - Synthesis

    private func schedule(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        oneShot.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private func makeTone(freq: Float, duration: Float, amplitude: Float,
                          secondHarmonic: Float, noiseMix: Float, decay: Float) -> AVAudioPCMBuffer? {
        let sr = Float(format.sampleRate)
        let frames = AVAudioFrameCount(duration * sr)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let twoPiF = 2 * Float.pi * freq / sr
        for i in 0..<Int(frames) {
            let t = Float(i)
            let env = expf(-decay * t / sr)               // fast percussive decay
            let fundamental = sinf(twoPiF * t)
            let harmonic = secondHarmonic * sinf(2 * twoPiF * t)
            let noise = noiseMix * (whiteNoise() * 2 - 1)
            ch[i] = amplitude * env * (fundamental + harmonic + noise)
        }
        return buffer
    }

    private func makeNoiseLoop(duration: Float) -> AVAudioPCMBuffer? {
        let sr = Float(format.sampleRate)
        let frames = AVAudioFrameCount(duration * sr)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        // Low-pass filtered noise → a soft rolling rumble rather than hiss.
        var lp: Float = 0
        for i in 0..<Int(frames) {
            let n = whiteNoise() * 2 - 1
            lp += (n - lp) * 0.04
            ch[i] = lp * 0.9
        }
        return buffer
    }

    /// Cheap, fast pseudo-noise in 0…1 (xorshift); deterministic, no allocations.
    private func whiteNoise() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) / Float(UInt32.max)
    }
}
