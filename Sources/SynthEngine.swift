import Foundation
import AVFoundation

/// One note instruction for the render thread. `holdSeconds < 0` means the
/// voice sustains until a matching note-off arrives (live monitoring); a
/// non-negative hold makes the voice release itself, which is what the weaver
/// uses so it never has to track note-offs.
struct SynthCommand {
    var isOn = true
    var id: Int32 = 0
    var freq: Double = 440
    var velocity: Float = 0.6
    var holdSeconds: Double = 1.0
    var pan: Float = 0
    var timbre: Int32 = 0
    var attack: Double = 0.4
    var release: Double = 2.0
}

/// Polyphonic pad voice bank. Everything the render thread touches is
/// preallocated; commands arrive through a try-lock queue.
final class SynthKernel {
    static let maxVoices = 40
    private static let partialCount = 4
    private static let tableSize = 4096

    /// Partial (ratio, amplitude) sets. Slight inharmonicity keeps long tones
    /// from sounding like a test oscillator.
    static let timbreNames = ["Glass", "Wood", "Deep", "Bell"]
    private static let timbres: [[(Double, Float)]] = [
        [(1.0, 1.0), (2.0, 0.34), (3.01, 0.16), (5.02, 0.06)],      // Glass
        [(1.0, 1.0), (2.76, 0.20), (5.41, 0.07), (0.5, 0.18)],      // Wood
        [(0.5, 0.42), (1.0, 1.0), (2.0, 0.24), (3.0, 0.08)],        // Deep
        [(1.0, 1.0), (2.0, 0.55), (2.99, 0.34), (4.21, 0.20)],      // Bell
    ]

    private struct Voice {
        var active = false
        var id: Int32 = 0
        var gated = false          // waiting for a note-off
        var stage: Int32 = 0       // 0 attack, 1 hold, 2 release
        var freq = 440.0
        var phase = (0.0, 0.0, 0.0, 0.0)
        var inc = (0.0, 0.0, 0.0, 0.0)
        var amp: (Float, Float, Float, Float) = (0, 0, 0, 0)
        var env: Float = 0
        var attackInc: Float = 0.001
        var releaseCoef: Float = 0.9999
        var holdFrames: Int32 = 0
        var vel: Float = 0.6
        var panL: Float = 0.707
        var panR: Float = 0.707
        var lfoPhase = 0.0
        var lfoInc = 0.0
        var lfoDepth: Float = 0.1
        var lp: Float = 0
        var lpCoef: Float = 0.4
    }

    let commands = EventQueue<SynthCommand>(capacity: 1024)

    /// Master level, read live from the UI.
    var masterVolume: Float = 0.85

    private let voices: UnsafeMutablePointer<Voice>
    private let sine: UnsafeMutablePointer<Float>
    private var sampleRate = 48000.0
    private var rng = Rng(seed: 0x51F0A3)
    /// Voice count, published for the UI (read without synchronization; it is
    /// only ever a display hint).
    private(set) var activeVoices: Int32 = 0

    init() {
        voices = UnsafeMutablePointer<Voice>.allocate(capacity: Self.maxVoices)
        voices.initialize(repeating: Voice(), count: Self.maxVoices)
        sine = UnsafeMutablePointer<Float>.allocate(capacity: Self.tableSize + 1)
        for i in 0...Self.tableSize {
            sine[i] = Float(sin(2 * Double.pi * Double(i) / Double(Self.tableSize)))
        }
    }

    deinit {
        voices.deallocate()
        sine.deallocate()
    }

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func allNotesOff() {
        var cmd = SynthCommand()
        cmd.isOn = false
        cmd.id = -1  // sentinel: release everything
        commands.push(cmd)
    }

    // MARK: - Render

    @inline(__always)
    private func lookup(_ phase: Double) -> Float {
        let p = phase - phase.rounded(.down)
        let x = p * Double(Self.tableSize)
        let i = Int(x)
        let frac = Float(x - Double(i))
        return sine[i] + (sine[i + 1] - sine[i]) * frac
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        drainCommands()

        for f in 0..<frames { left[f] = 0; right[f] = 0 }

        var live: Int32 = 0
        for v in 0..<Self.maxVoices {
            guard voices[v].active else { continue }
            live += 1
            var voice = voices[v]
            for f in 0..<frames {
                // Envelope
                switch voice.stage {
                case 0:
                    voice.env += voice.attackInc
                    if voice.env >= 1 { voice.env = 1; voice.stage = 1 }
                case 1:
                    if !voice.gated {
                        voice.holdFrames -= 1
                        if voice.holdFrames <= 0 { voice.stage = 2 }
                    }
                default:
                    voice.env *= voice.releaseCoef
                }
                if voice.stage == 2 && voice.env < 0.0002 {
                    voice.active = false
                    break
                }

                // Slow tremolo keeps sustained tones breathing.
                voice.lfoPhase += voice.lfoInc
                if voice.lfoPhase >= 1 { voice.lfoPhase -= 1 }
                let lfo = 1 + voice.lfoDepth * lookup(voice.lfoPhase)

                var s = lookup(voice.phase.0) * voice.amp.0
                s += lookup(voice.phase.1) * voice.amp.1
                s += lookup(voice.phase.2) * voice.amp.2
                s += lookup(voice.phase.3) * voice.amp.3
                voice.phase.0 += voice.inc.0
                voice.phase.1 += voice.inc.1
                voice.phase.2 += voice.inc.2
                voice.phase.3 += voice.inc.3
                if voice.phase.0 >= 1 { voice.phase.0 -= 1 }
                if voice.phase.1 >= 1 { voice.phase.1 -= 1 }
                if voice.phase.2 >= 1 { voice.phase.2 -= 1 }
                if voice.phase.3 >= 1 { voice.phase.3 -= 1 }

                // One-pole lowpass: quiet notes sit further back.
                voice.lp += (s - voice.lp) * voice.lpCoef
                // env^1.6 softens the attack knee without a second segment.
                let shaped = voice.env * voice.env * (0.6 + 0.4 * voice.env)
                let out = voice.lp * shaped * voice.vel * lfo

                left[f] += out * voice.panL
                right[f] += out * voice.panR
            }
            voices[v] = voice
        }
        activeVoices = live

        // Headroom. Four layers of phrases over a drone sum well past full
        // scale, and the delay and reverb downstream only add to it — without
        // this the mix leans on the limiter continuously instead of keeping it
        // as a safety net, and the tanh spends its time distorting rather than
        // catching peaks. Ambient does not want to be loud; the level slider is
        // there for anyone who disagrees.
        let gain = masterVolume * 0.75
        for f in 0..<frames {
            left[f] = tanh(left[f] * 0.55) * gain
            right[f] = tanh(right[f] * 0.55) * gain
        }
    }

    // MARK: - Command handling

    private func drainCommands() {
        commands.drain { cmd in
            if cmd.isOn {
                self.startVoice(cmd)
            } else if cmd.id == -1 {
                for v in 0..<Self.maxVoices where self.voices[v].active {
                    self.voices[v].gated = false
                    self.voices[v].stage = 2
                }
            } else {
                for v in 0..<Self.maxVoices where self.voices[v].active && self.voices[v].id == cmd.id {
                    self.voices[v].gated = false
                    self.voices[v].stage = 2
                }
            }
        }
    }

    private func startVoice(_ cmd: SynthCommand) {
        var slot = -1
        var quietest: Float = .greatestFiniteMagnitude
        for v in 0..<Self.maxVoices {
            if !voices[v].active { slot = v; break }
            // Steal the quietest releasing voice, else the quietest voice.
            let metric = voices[v].env * (voices[v].stage == 2 ? 0.5 : 1)
            if metric < quietest { quietest = metric; slot = v }
        }
        guard slot >= 0 else { return }

        let t = Int(max(0, min(Int32(Self.timbres.count - 1), cmd.timbre)))
        let set = Self.timbres[t]
        var voice = Voice()
        voice.active = true
        voice.id = cmd.id
        voice.gated = cmd.holdSeconds < 0
        voice.stage = 0
        voice.freq = cmd.freq
        voice.vel = max(0.02, min(1.2, cmd.velocity))

        // A hair of detune per voice so stacked phrases beat against each other.
        let detune = 1 + (rng.unit() - 0.5) * 0.0035
        var incs = (0.0, 0.0, 0.0, 0.0)
        var amps: (Float, Float, Float, Float) = (0, 0, 0, 0)
        for (i, partial) in set.enumerated() {
            let f = cmd.freq * partial.0 * detune
            // Fold anything past Nyquist away instead of aliasing it.
            let inc = f < sampleRate * 0.45 ? f / sampleRate : 0
            var amp = f < sampleRate * 0.45 ? partial.1 : 0
            // Roll off the subsonic end too. The Deep timbre's half-frequency
            // partial puts the drone's fundamental around 32 Hz, which most
            // speakers cannot reproduce but which happily eats headroom and
            // drives the reverb.
            if f < 45 { amp *= Float(max(0, min(1, (f - 25) / 20))) }
            switch i {
            case 0: incs.0 = inc; amps.0 = amp
            case 1: incs.1 = inc; amps.1 = amp
            case 2: incs.2 = inc; amps.2 = amp
            default: incs.3 = inc; amps.3 = amp
            }
        }
        voice.inc = incs
        voice.amp = amps
        voice.phase = (rng.unit(), rng.unit(), rng.unit(), rng.unit())

        let attack = max(0.004, cmd.attack)
        voice.attackInc = Float(1.0 / (attack * sampleRate))
        let release = max(0.05, cmd.release)
        voice.releaseCoef = Float(pow(0.0001, 1.0 / (release * sampleRate)))
        voice.holdFrames = Int32(max(0, cmd.holdSeconds) * sampleRate)

        let pan = max(-1, min(1, cmd.pan))
        let angle = (pan + 1) * 0.25 * Float.pi
        voice.panL = cos(angle)
        voice.panR = sin(angle)

        voice.lfoInc = (0.05 + rng.unit() * 0.35) / sampleRate
        voice.lfoPhase = rng.unit()
        voice.lfoDepth = Float(0.05 + rng.unit() * 0.12)

        // Softer notes get a darker filter, so dynamics read as depth.
        let cutoff = 700.0 + Double(voice.vel) * 5200.0
        voice.lpCoef = Float(min(0.999, 1 - exp(-2 * Double.pi * cutoff / sampleRate)))

        voices[slot] = voice
    }
}

/// A selectable voice tone, for the interface.
struct Timbre: Hashable, Identifiable {
    let index: Int32
    var id: Int32 { index }
    var name: String { SynthKernel.timbreNames[Int(index)] }

    static let all = SynthKernel.timbreNames.indices.map { Timbre(index: Int32($0)) }

    static func named(_ index: Int32) -> Timbre {
        all.first { $0.index == index } ?? all[0]
    }
}

/// AVAudioEngine wiring: pad voices into a long delay and a big reverb, which
/// is most of what makes this sound like ambient rather than a synth demo.
final class AudioOutput {
    let kernel = SynthKernel()

    private let engine = AVAudioEngine()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    /// Final brick wall. The kernel's own tanh only protects the voice bank —
    /// the delay's feedback and the reverb's build-up happen after it, and a
    /// continuous low drone feeding both is exactly the case that runs away.
    private let limiter = AVAudioUnitEffect(audioComponentDescription:
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_PeakLimiter,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0))
    private var sourceNode: AVAudioSourceNode?

    var delayMix: Float = 28 { didSet { delay.wetDryMix = delayMix } }
    var delayFeedback: Float = 42 { didSet { delay.feedback = delayFeedback } }
    var reverbMix: Float = 58 { didSet { reverb.wetDryMix = reverbMix } }
    /// Delay time follows the tempo (a dotted half at the session BPM).
    var delaySeconds: Double = 1.5 { didSet { delay.delayTime = min(2, max(0.05, delaySeconds)) } }

    /// `offline` swaps the sound card for manual rendering, so the whole chain
    /// — voices, delay and reverb together — can be measured without playing
    /// anything. That is the only honest way to check output levels: the
    /// limiter and the reverb build-up are invisible if you only look at the
    /// voice bank.
    init(offline: Bool = false) {
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = offline ? 48000 : (hardwareRate > 0 ? hardwareRate : 48000)
        kernel.prepare(sampleRate: rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

        let kernel = self.kernel
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            kernel.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.attach(delay)
        engine.attach(reverb)
        engine.attach(limiter)

        delay.delayTime = 1.5
        delay.feedback = delayFeedback
        delay.wetDryMix = delayMix
        delay.lowPassCutoff = 3200
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = reverbMix

        engine.connect(node, to: delay, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        if offline {
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
    }

    /// Renders `seconds` of the whole chain, handing each block to `block`.
    /// Offline instances only.
    func renderOffline(seconds: Double, _ block: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) {
        guard engine.manualRenderingMode == .offline,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: 1024) else { return }
        var remaining = Int(seconds * engine.manualRenderingFormat.sampleRate)
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(1024, remaining))
            guard let status = try? engine.renderOffline(frames, to: buffer), status == .success,
                  let channels = buffer.floatChannelData else { return }
            block(channels[0], channels[1], Int(buffer.frameLength))
            remaining -= Int(frames)
        }
    }

    func start() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Echo: audio engine failed to start: \(error)")
        }
    }

    func stop() {
        kernel.allNotesOff()
        engine.stop()
    }

    var activeVoices: Int { Int(kernel.activeVoices) }
}
