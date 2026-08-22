import Foundation

/// A phrase in the vocabulary, plus everything that governs how it recurs.
final class VocabEntry {
    let phrase: Phrase
    let fragments: [[Int]]
    let seed: UInt32
    var weight: Double
    /// Recurrence period in beats — always a prime.
    var period: Int
    var offset: Int
    var playCount = 0
    var soundingUntil: Double = 0
    var timbre: Int
    var basePan: Float
    /// Primes gating each manipulation for this entry. Distinct where possible,
    /// so a phrase's arpeggios, tape moves and reversals never coincide on a
    /// schedule of their own.
    var arpPrime: Int
    var tapePrime: Int
    var reversePrime: Int
    var shufflePrime: Int
    var lastTranspose = 0
    var lastArpeggiated = false
    var lastTaped = 0        // -1 down an octave at half speed, +1 up at double
    var lastReversed = false
    var lastShuffled = false
    var lastFragment: [Int] = []
    var lastFiredBeat = -1

    init(phrase: Phrase, fragments: [[Int]], weight: Double, seed: UInt32) {
        self.phrase = phrase
        self.fragments = fragments
        self.weight = weight
        self.seed = seed
        self.period = 13
        self.offset = 0
        var rng = Rng(seed: seed)
        self.timbre = phrase.isChord ? (rng.chance(0.55) ? 0 : 2) : rng.int(0..<4)
        self.basePan = Float(rng.unit() * 1.4 - 0.7)
        // Deal three different primes from the small set, so the three
        // manipulations recur on independent cycles.
        var pool = [2, 3, 5, 7]
        func take() -> Int {
            guard !pool.isEmpty else { return 3 }
            return pool.remove(at: rng.int(0..<pool.count))
        }
        self.arpPrime = take()
        self.tapePrime = take()
        self.reversePrime = take()
        self.shufflePrime = take()
    }

    /// Where this phrase sits on the wheel once its last transposition is
    /// taken into account.
    var effectiveCamelot: Camelot { Camelot(phrase.key.transposed(by: lastTranspose)) }
}

// MARK: - Snapshots for the UI

/// One note in a phrase's thumbnail, normalized to 0...1.
struct GlyphDot: Equatable {
    var x: Double
    var y: Double
    var on: Bool
}

/// Equatable so SwiftUI can skip redrawing rows that have not changed — with
/// snapshots arriving ten times a second, that is most of them.
struct PhraseCard: Identifiable, Equatable {
    var id: Int
    var label: String
    var isChord: Bool
    var keyName: String
    var camelot: String
    var prime: Int
    var weight: Double
    var playCount: Int
    var beatsUntilNext: Int
    var sounding: Bool
    var transpose: Int
    var arpeggiated: Bool
    /// -1 down an octave at half speed, +1 up at double, 0 not taped.
    var taped: Int
    var reversed: Bool
    var shuffled: Bool
    var isNewest: Bool
    var glyph: [GlyphDot]
}

/// What Echo heard most recently, so the interface can show it and offer to
/// throw it away. `reinforced` means it was a phrase already in the vocabulary
/// played again rather than new material.
struct LearnedPhrase: Equatable {
    var id: Int
    var ageSeconds: Double
    var reinforced: Bool
}

struct WeaverSnapshot {
    var beat = 0
    var barPhase = 0.0
    var sessionKey = MusicKey(tonic: 0, isMinor: false)
    var sessionCamelot = "8B"
    var keyConfidence = 0.0
    var cards: [PhraseCard] = []
    var soundingCamelots: [String] = []
    var voices = 0
    var hearingInput = false
    var notesInProgress = 0
    var newest: LearnedPhrase?
}

/// The two streams Echo produces. They are routed independently, so the app
/// can hold the bed while an external instrument plays the phrases.
enum Part {
    case phrase
    case bed
}

/// Where a stream goes.
enum Route: String, CaseIterable, Identifiable {
    case synth
    case midi
    case both

    var id: String { rawValue }
    var label: String { rawValue }
    var toSynth: Bool { self != .midi }
    var toMIDI: Bool { self != .synth }
}

/// One note Echo has decided to play, before it is committed to the internal
/// synth, to MIDI out, or both. Pitch is kept (not just frequency) because MIDI
/// needs the note number.
struct Voicing {
    /// 0 for fire-and-forget. A non-zero id can be released early — which is
    /// what lets the bed change tone without waiting out its current note.
    var id: Int32 = 0
    var pitch: Int
    var velocity: Float
    var hold: Double
    var pan: Float
    var timbre: Int32
    var attack: Double
    var release: Double
    var part: Part

    var synthCommand: SynthCommand {
        var cmd = SynthCommand()
        cmd.id = id
        cmd.freq = Pitch.frequency(pitch)
        cmd.velocity = max(0.03, min(1.0, velocity))
        cmd.holdSeconds = hold
        cmd.timbre = timbre
        cmd.pan = pan
        cmd.attack = attack
        cmd.release = release
        return cmd
    }
}

// MARK: - Weaver

/// The composer. Holds the vocabulary, runs the beat clock, and decides which
/// fragment of which phrase sounds when — on prime periods, layered by
/// Camelot compatibility with whatever is already ringing.
final class Weaver {
    // Live settings, written from the UI thread and read on the weaver queue.
    var bpm: Double = 58 { didSet { spb = 60.0 / max(20, bpm) } }
    /// 0...1 — scales how often phrases recur.
    var density: Double = 0.5 { didSet { queue.async { self.assignPeriods() } } }
    /// Simultaneous phrases allowed.
    var maxLayers: Int = 4
    /// 0...1 — how often chords break into arpeggios.
    var arpeggioAmount: Double = 0.45
    /// 0...1 — how often a phrase is played back like tape at another speed:
    /// down an octave at half speed, or up an octave at double. Pitch and time
    /// move together, which is what makes it read as the same gesture rather
    /// than a different one.
    var tapeAmount: Double = 0.30
    /// 0...1 — how often a phrase plays backwards.
    var reverseAmount: Double = 0.30
    /// 0...1 — how often the notes of a phrase are dealt into a different
    /// order while keeping their timing, so the rhythm survives and the melody
    /// does not.
    var shuffleAmount: Double = 0.25
    /// 0...1 — how hard Echo pulls phrases toward the session key. At 0 it
    /// stacks them as played; at 1 everything is transposed into the key.
    var harmonicPull: Double = 0.7
    var droneEnabled = true
    var learning = true
    var playing = true
    /// Whether Echo also sounds what you play. Off by default: anything that
    /// can send MIDI usually makes its own sound, and doubling it is never what
    /// you want. Turn it on for a controller that has no voice of its own.
    var monitorInput = false
    var vocabularyLimit = 24 { didSet { queue.async { self.assignPeriods() } } }

    /// Where the phrases go, and where the bed goes. The point of splitting
    /// them: let an external instrument play the chords and melodies while Echo
    /// keeps the drone underneath.
    var phraseRoute: Route = .synth
    var bedRoute: Route = .synth
    /// Which voice tone the bed uses. Changing it restarts the bed straight
    /// away — waiting 23 beats to hear the tone you just picked is no way to
    /// choose one.
    var bedTimbre: Int32 = 2 {
        didSet {
            guard bedTimbre != oldValue else { return }
            queue.async { self.restartBed() }
        }
    }
    /// MIDI out, if the app wired one up.
    weak var midiOut: MIDIOutput?
    /// Notified of every note Echo emits, to arm its loopback guard.
    weak var midiIn: MIDIInput? { didSet { queue.async { self.assignPeriods() } } }

    var onSnapshot: ((WeaverSnapshot) -> Void)?

    private let synth: SynthKernel
    private let listener = PhraseListener()
    private let queue = DispatchQueue(label: "com.jeffhobbs.echo.weaver", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private var entries: [VocabEntry] = []
    private var spb: Double = 60.0 / 58.0
    private var beat = 0
    private var nextBeatTime: Double = 0
    /// Timed queue of everything still to happen. Note-offs for MIDI live here
    /// too, which is what keeps external instruments from hanging.
    private enum Event {
        case play(Voicing)
        case releaseVoice(id: Int32)
        case midiOff(pitch: Int, channel: UInt8)
    }

    private struct Scheduled {
        var time: Double
        var event: Event
    }

    private var pending: [Scheduled] = []
    private var rng = Rng(seed: 0xEC4051)
    private var seedCounter: UInt32 = 7

    /// Rolling, decaying pitch-class histogram of what the player has played.
    private var sessionHistogram = [Double](repeating: 0, count: 12)
    private var sessionKey = MusicKey(tonic: 0, isMinor: false)
    private var sessionConfidence = 0.0
    private var droneCounter = 0
    /// The bed sounds on one reserved voice, so it can be released on purpose.
    private static let bedVoiceID: Int32 = 7000
    private var lastBedPitch: Int?
    private var lastSnapshot: Double = 0
    /// The clock reading the weaver last acted on. Anything scheduled outside
    /// the beat loop uses this rather than reading the wall clock directly, so
    /// the weaver stays agnostic about what is driving it — the real timer in
    /// the app, or a synthetic clock in a test.
    private var currentTime: Double = 0

    /// Set when the UI wants a phrase heard immediately.
    private var auditionRequests: [Int] = []

    /// The most recent thing Echo learned, kept so the interface can offer to
    /// discard it without hunting for it in a list sorted by weight.
    private var lastLearned: (id: Int, at: Double, reinforced: Bool)?

    /// One line per entrance. Off by default; the offline analysis harness
    /// turns it on to check that the prime periods really do keep the texture
    /// from repeating.
    struct FireLog {
        var beat: Int
        var id: Int
        var prime: Int
        var camelot: String
        var transpose: Int
        var arpeggiated: Bool
        var taped: Int
        var reversed: Bool
        var shuffled: Bool
        var layers: Int
        var notes: Int
        var lowestPitch: Int
        var firstPitch: Int
        var lastPitch: Int
        /// First onset to last, in seconds — halves and doubles with tape.
        var spanSeconds: Double
        /// The fragment as it was played, before any transform: the reference
        /// a test can check the transforms against without asking the code to
        /// confirm its own arithmetic.
        var sourceFirstPitch: Int
        var sourceSpanBeats: Double
        /// The fragment's own onsets and pitches, and what actually came out,
        /// so a test can check a transform without re-deriving it.
        var sourceOnsets: [Double]
        var sourcePitches: [Int]
        var emittedOnsets: [Double]
        var emittedPitches: [Int]
        var longestHold: Double
        /// Longest hold among the notes actually in the bass, which is the
        /// figure that decides whether an airing drones.
        var longestBassHold: Double
    }

    var debugLogging = false
    private(set) var fireLog: [FireLog] = []

    init(synth: SynthKernel) {
        self.synth = synth
        listener.onPhrase = { [weak self] phrase in self?.absorb(phrase) }
        listener.bpm = bpm
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.nextBeatTime = Clock.now()
            self.beat = 0
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - MIDI in

    func noteOn(pitch: Int, velocity: Float, time: Double) {
        queue.async {
            self.listener.bpm = self.bpm
            if self.learning { self.listener.noteOn(pitch: pitch, velocity: velocity, time: time) }
            let weight = max(0.08, Double(velocity)) * max(0.05, Double(velocity))
            self.sessionHistogram[((pitch % 12) + 12) % 12] += 1.0 + weight
            if self.monitorInput {
                var cmd = SynthCommand()
                cmd.id = Int32(9000 + pitch)
                cmd.freq = Pitch.frequency(pitch)
                cmd.velocity = velocity * 0.75
                cmd.holdSeconds = -1
                cmd.pan = 0
                cmd.timbre = 0
                cmd.attack = 0.05
                cmd.release = 2.2
                self.synth.commands.push(cmd)
            }
        }
    }

    func noteOff(pitch: Int, time: Double) {
        queue.async {
            if self.learning { self.listener.noteOff(pitch: pitch, time: time) }
            var cmd = SynthCommand()
            cmd.isOn = false
            cmd.id = Int32(9000 + pitch)
            self.synth.commands.push(cmd)
        }
    }

    /// The controller sent all-notes-off or reset-all-controllers.
    func inputAllNotesOff() {
        let now = Clock.now()
        queue.async { self.listener.allNotesOff(time: now) }
    }

    func setSustain(_ down: Bool) {
        let now = Clock.now()
        queue.async { self.listener.setSustain(down, time: now) }
    }

    // MARK: - Vocabulary

    func clearVocabulary() {
        queue.async {
            self.lastLearned = nil
            self.entries.removeAll()
            self.listener.reset()
            self.sessionHistogram = [Double](repeating: 0, count: 12)
        }
    }

    func forget(id: Int) {
        queue.async {
            self.entries.removeAll { $0.phrase.id == id }
            if self.lastLearned?.id == id { self.lastLearned = nil }
            self.assignPeriods()
        }
    }

    /// Throw away whatever Echo learned last — the whole point of showing it.
    func forgetLastLearned() {
        queue.async {
            guard let id = self.lastLearned?.id else { return }
            self.entries.removeAll { $0.phrase.id == id }
            self.lastLearned = nil
            self.assignPeriods()
        }
    }

    /// Hand back everything the weaver holds. Runs on the weaver queue and
    /// answers on the main one, since that is where the save panel lives.
    func exportWeave(completion: @escaping (EchoSession.Weave) -> Void) {
        queue.async {
            let weave = EchoSession.Weave(beat: self.beat,
                                          histogram: self.sessionHistogram,
                                          phrases: self.entries.map {
                                              $0.phrase.stored(weight: $0.weight,
                                                               seed: $0.seed,
                                                               playCount: $0.playCount)
                                          })
            DispatchQueue.main.async { completion(weave) }
        }
    }

    /// Put the weaver back where a saved session left it.
    func importWeave(_ set: EchoSession.Weave) {
        queue.async {
            self.entries.removeAll()
            self.lastLearned = nil
            self.pending.removeAll()
            self.synth.allNotesOff()
            self.midiOut?.allNotesOff()

            for stored in set.phrases {
                let phrase = Phrase(stored: stored)
                let fragments = Fragmenter.fragments(for: phrase)
                guard !fragments.isEmpty else { continue }
                let entry = VocabEntry(phrase: phrase,
                                       fragments: fragments,
                                       weight: stored.weight,
                                       seed: stored.seed)
                // Carrying the play count over keeps each phrase where it was
                // in its own manipulation cycles.
                entry.playCount = stored.playCount
                self.entries.append(entry)
            }
            // The saved histogram carries the session key, so the piece resumes
            // in the key it had drifted to instead of sitting in C until the
            // player happens to touch something. Older or hand-made files may
            // not have one; fall back to what the phrases themselves imply.
            if set.histogram.count == 12, set.histogram.contains(where: { $0 > 0 }) {
                self.sessionHistogram = set.histogram
            } else {
                var implied = [Double](repeating: 0, count: 12)
                for entry in self.entries {
                    for (i, value) in Phrase.histogram(entry.phrase.notes).enumerated() {
                        implied[i] += value
                    }
                }
                self.sessionHistogram = implied
            }
            self.detectSessionKey()
            // Resume the beat count, so every phrase is due exactly when it was.
            self.beat = set.beat
            self.nextBeatTime = Clock.now()
            self.listener.ensureNextID(above: set.phrases.map(\.id).max() ?? 0)
            self.assignPeriods()
        }
    }

    func audition(id: Int) {
        queue.async { self.auditionRequests.append(id) }
    }

    func nudge(id: Int, by delta: Double) {
        queue.async {
            guard let entry = self.entries.first(where: { $0.phrase.id == id }) else { return }
            entry.weight = min(1.0, max(0.06, entry.weight + delta))
            self.assignPeriods()
        }
    }

    /// Playing a phrase again should reinforce it rather than add another copy
    /// — a vocabulary holding ten near-identical entries has stopped being a
    /// vocabulary. Matching is on interval shape and rhythm, so the same figure
    /// in another register counts as the same word (Echo transposes freely
    /// anyway).
    private func existingEntry(matching phrase: Phrase) -> VocabEntry? {
        let shape = phrase.shape
        guard !shape.isEmpty else { return nil }
        for entry in entries where entry.phrase.isChord == phrase.isChord && entry.phrase.shape == shape {
            if phrase.isChord { return entry }
            // Lines also have to agree rhythmically to count as the same phrase.
            let played = entry.phrase.notes
            guard played.count == phrase.notes.count else { continue }
            let sameRhythm = zip(played, phrase.notes).allSatisfy {
                abs($0.onsetBeats - $1.onsetBeats) < 0.3
            }
            if sameRhythm { return entry }
        }
        return nil
    }

    func absorb(_ phrase: Phrase) {
        if let existing = existingEntry(matching: phrase) {
            existing.weight = min(1.0, existing.weight + 0.2)
            lastLearned = (existing.phrase.id, Clock.now(), true)
            assignPeriods()
            return
        }
        let fragments = Fragmenter.fragments(for: phrase)
        guard !fragments.isEmpty else { return }
        // Louder, longer, more note-dense phrases start out more present.
        let base = 0.34
            + 0.30 * Double(phrase.averageVelocity)
            + 0.16 * min(1, Double(phrase.notes.count) / 6.0)
            + 0.10 * phrase.keyConfidence
        seedCounter = seedCounter &* 2_654_435_761 &+ 12345
        let entry = VocabEntry(phrase: phrase,
                              fragments: fragments,
                              weight: min(1.0, base),
                              seed: seedCounter | 1)
        entries.append(entry)
        lastLearned = (phrase.id, Clock.now(), false)

        // Over the limit: the faintest phrase makes room for the newest.
        if entries.count > vocabularyLimit {
            entries.sort { $0.weight > $1.weight }
            entries.removeLast(entries.count - vocabularyLimit)
        }
        assignPeriods()
    }

    /// Hand out distinct primes: the heaviest phrases get the shortest
    /// periods, and offsets are staggered so firings do not pile up.
    ///
    /// Presence is relative, not absolute. Every airing costs a phrase a
    /// little weight, so judging periods on raw weight would let the whole
    /// vocabulary drift toward its longest periods and the piece would slowly
    /// starve. Normalizing against the loudest phrase and blending in rank
    /// keeps the spread constant however long Echo has been running.
    private func assignPeriods() {
        let ordered = entries.sorted { $0.weight > $1.weight }
        guard !ordered.isEmpty else { return }
        let ceiling = max(0.001, ordered[0].weight)
        var taken = Set<Int>()
        for (index, entry) in ordered.enumerated() {
            let normalized = entry.weight / ceiling
            let rank = 1 - Double(index) / Double(max(2, ordered.count))
            // Density stretches or compresses the whole vocabulary at once.
            let presence = (0.55 * normalized + 0.45 * rank) * (0.45 + 0.75 * density)
            let period = Primes.period(forWeight: min(1, max(0, presence)), taken: taken)
            taken.insert(period)
            entry.period = period
            entry.offset = (index * 7 + Int(entry.seed % 11)) % period
        }
    }

    // MARK: - Clock

    private func tick() {
        let now = Clock.now()
        currentTime = now
        listener.bpm = bpm
        listener.tick(now: now)

        if playing {
            if nextBeatTime == 0 { nextBeatTime = now }
            while nextBeatTime <= now {
                onBeat(beat, at: max(nextBeatTime, now))
                beat += 1
                nextBeatTime += spb
            }
        } else {
            nextBeatTime = now
        }

        // Release anything that has come due.
        while let first = pending.first, first.time <= now + 0.006 {
            pending.removeFirst()
            dispatch(first, at: now)
        }

        if now - lastSnapshot > 0.1 {
            lastSnapshot = now
            publishSnapshot(now: now)
        }
    }

    /// Commits one scheduled event to whichever outputs its part is routed to.
    private func dispatch(_ item: Scheduled, at now: Double) {
        switch item.event {
        case .play(let voicing):
            let route = voicing.part == .phrase ? phraseRoute : bedRoute
            if route.toSynth {
                synth.commands.push(voicing.synthCommand)
            }
            if route.toMIDI, let out = midiOut {
                let channel: UInt8 = voicing.part == .phrase ? 0 : 1
                out.noteOn(pitch: voicing.pitch, velocity: voicing.velocity, channel: channel)
                midiIn?.noteWasSent(pitch: voicing.pitch, at: now)
                // The matching off is queued now, so it survives a route change.
                enqueue(.midiOff(pitch: voicing.pitch, channel: channel), at: item.time + voicing.hold)
            }
        case .releaseVoice(let id):
            var cmd = SynthCommand()
            cmd.isOn = false
            cmd.id = id
            synth.commands.push(cmd)
        case .midiOff(let pitch, let channel):
            midiOut?.noteOff(pitch: pitch, channel: channel)
        }
    }

    func onBeat(_ beat: Int, at time: Double) {
        if beat % 8 == 0 { refreshSessionKey() }
        if beat % 128 == 127 {
            // Slow forgetting, then re-sort the primes around the new weights.
            for entry in entries { entry.weight = max(0.06, entry.weight * 0.985) }
            assignPeriods()
        }

        // Anything the UI asked to hear jumps the queue.
        if !auditionRequests.isEmpty {
            let ids = auditionRequests
            auditionRequests.removeAll()
            for id in ids {
                if let entry = entries.first(where: { $0.phrase.id == id }) {
                    play(entry, at: time, layers: 0, force: true)
                }
            }
        }

        guard playing else { return }

        if droneEnabled { maybeDrone(beat: beat, at: time) }

        // Candidates for this beat: a phrase fires when the beat count lands
        // on its prime period. Coprime periods mean the combination of
        // phrases sounding together never repeats.
        var candidates = entries.filter { entry in
            entry.period > 0 && (((beat - entry.offset) % entry.period) + entry.period) % entry.period == 0
        }
        guard !candidates.isEmpty else { return }
        candidates.sort { $0.weight > $1.weight }

        var starts = 0
        for entry in candidates {
            let layers = entries.reduce(0) { $0 + ($1.soundingUntil > time ? 1 : 0) }
            if layers >= maxLayers { break }
            if starts >= 2 { break }               // never more than two entrances at once
            if entry.soundingUntil > time { continue }  // still ringing; let it be
            if play(entry, at: time, layers: layers, force: false) { starts += 1 }
        }
    }

    // MARK: - Session key

    private func refreshSessionKey() {
        // Decay so the key follows the player instead of averaging the session.
        for i in 0..<12 { sessionHistogram[i] *= 0.94 }
        detectSessionKey()
    }

    /// Read the key without aging the histogram — what a freshly opened session
    /// wants, since its histogram is exactly as old as it was when saved.
    private func detectSessionKey() {
        if let detected = KeyFinder.detect(sessionHistogram) {
            sessionKey = detected.key
            sessionConfidence = detected.confidence
        }
    }

    /// The harmonic context a new phrase has to fit into: the session key,
    /// plus whatever is still ringing, weighted.
    private func context(at time: Double) -> [(camelot: Camelot, weight: Double)] {
        var ctx: [(Camelot, Double)] = [(Camelot(sessionKey), 0.6 + 0.6 * sessionConfidence)]
        for entry in entries where entry.soundingUntil > time {
            ctx.append((entry.effectiveCamelot, 0.8 * entry.weight + 0.2))
        }
        return ctx
    }

    private func score(_ candidate: Camelot, in ctx: [(camelot: Camelot, weight: Double)]) -> Double {
        guard !ctx.isEmpty else { return 1 }
        var total = 0.0, mass = 0.0
        for item in ctx {
            total += candidate.compatibility(with: item.camelot) * item.weight
            mass += item.weight
        }
        return mass > 0 ? total / mass : 1
    }

    /// Pick a transposition that makes this phrase sit well on top of what is
    /// already sounding. Candidates are: leave it alone, move it into the
    /// session key, or move it to a neighbor on the wheel (a fifth away).
    private func chooseTranspose(for entry: VocabEntry, at time: Double) -> Int {
        let ctx = context(at: time)
        let home = entry.phrase.key
        let toKey = home.shift(to: sessionKey)
        var options = Set([0, toKey])
        for interval in [7, -7, 5, -5, 2, -2] {
            var shifted = toKey + interval
            if shifted > 6 { shifted -= 12 }
            if shifted < -6 { shifted += 12 }
            options.insert(shifted)
        }

        var scored: [(shift: Int, weight: Double)] = []
        for shift in options {
            let camelot = Camelot(home.transposed(by: shift))
            var s = score(camelot, in: ctx)
            // Bias toward the key by however much pull the user asked for.
            if shift == toKey { s += 0.35 * harmonicPull }
            if shift == 0 { s += 0.25 * (1 - harmonicPull) }
            // Big moves drag the phrase out of its register.
            s -= 0.02 * Double(abs(shift))
            scored.append((shift, pow(max(0.02, s), 3 + 4 * harmonicPull)))
        }

        let total = scored.reduce(0) { $0 + $1.weight }
        var pick = rng.unit() * total
        for option in scored.sorted(by: { $0.weight > $1.weight }) {
            pick -= option.weight
            if pick <= 0 { return option.shift }
        }
        return toKey
    }

    // MARK: - Playback

    @discardableResult
    private func play(_ entry: VocabEntry, at time: Double, layers: Int, force: Bool) -> Bool {
        guard !entry.fragments.isEmpty else { return false }
        var local = Rng(seed: entry.seed ^ UInt32(truncatingIfNeeded: entry.playCount &* 2_654_435_761))

        // Chords occasionally break into an arpeggio instead of a block chord.
        // The gate is one of the entry's own primes, so arpeggios never settle
        // into a pattern of their own.
        let phraseSpan = (entry.phrase.notes.map(\.onsetBeats).max() ?? 0)
            - (entry.phrase.notes.map(\.onsetBeats).min() ?? 0)
        let chordish = entry.phrase.notes.count >= 3 && (entry.phrase.isChord || phraseSpan < 0.3)
        let arpeggiate = chordish
            && entry.playCount % entry.arpPrime == 0
            && local.chance(arpeggioAmount)

        // Shuffle is decided here, alongside arpeggio, for the same reason: so
        // the fragment can be chosen to suit it. Judged the other way round —
        // letting whichever fragment came up decide — a two-note slice vetoes
        // the shuffle and the slider never reaches the rate it promises.
        let shuffleWanted = !arpeggiate
            && entry.phrase.notes.count >= 3 && phraseSpan >= 0.3
            && entry.playCount % entry.shufflePrime == 0
            && local.chance(shuffleAmount)

        // Which fragment: step through the list by a prime, so the sequence of
        // fragments visits all of them without ever cycling in step with the
        // phrase's own period.
        let step = Primes.step(for: entry.fragments.count, seed: Int(entry.seed % 97))
        let index = (entry.playCount * step) % entry.fragments.count
        var fragment = entry.fragments[index]
        if arpeggiate || shuffleWanted {
            // An arpeggio needs something to spread and a shuffle needs
            // something to re-order, so both pass over the shell and
            // single-note fragments this time around.
            let spreadable = entry.fragments.filter { $0.count >= 3 }
            if !spreadable.isEmpty {
                fragment = spreadable[(entry.playCount * step) % spreadable.count]
            }
        }
        let notes = fragment.map { entry.phrase.notes[$0] }
        guard !notes.isEmpty else { return false }

        let transpose = chooseTranspose(for: entry, at: time)

        // These need a gesture with some time in it: there is nothing to slow
        // down, turn around or re-order in a block chord. Judged on the
        // fragment actually being played, not the phrase it came from, so a
        // badge never claims a transform that was inaudible.
        let fragmentSpan = (notes.map(\.onsetBeats).max() ?? 0) - (notes.map(\.onsetBeats).min() ?? 0)
        let hasSpread = notes.count >= 2 && fragmentSpan >= 0.25

        // Tape: pitch and speed locked, the way a tape machine couples them.
        // Down an octave at half speed, or up an octave at double.
        var tape = 0
        if hasSpread, entry.playCount % entry.tapePrime == 0, local.chance(tapeAmount) {
            tape = (entry.playCount / max(1, entry.tapePrime)) % 2 == 0 ? -1 : 1
        }

        // Reverse: the phrase plays backwards. Pointless on a chord, and
        // redundant under an arpeggio, which has descending patterns of its own.
        // The timing stays, the notes move to different slots in it.
        let shuffled = shuffleWanted && notes.count >= 3 && fragmentSpan >= 0.25

        // Reverse: the phrase plays backwards. Pointless on a chord, and
        // redundant under an arpeggio or a shuffle, both of which already
        // decide the order.
        let reversed = hasSpread && !arpeggiate && !shuffled
            && entry.playCount % entry.reversePrime == 0
            && local.chance(reverseAmount)

        // Time and register otherwise drift gently, prime-stepped. The dramatic
        // halving and doubling belongs to tape now, where the pitch moves with
        // it — an uncoupled half-speed pass and a coupled one are different
        // effects and having both fire freely muddied each other.
        let rates = [1.0, 1.0, 1.0, 1.5, 2.0 / 3.0]
        let octaves = [0, 0, 0, -12, 12, -12]
        let rate: Double
        let octave: Int
        switch tape {
        // `rate` scales the note timings, so it is a duration multiplier, not
        // a speed one: 2.0 is half speed, 0.5 is double. Slowing down goes with
        // dropping an octave, the way it does on a tape machine.
        case -1: rate = 2.0;  octave = -12
        case 1:  rate = 0.5;  octave = 12
        default:
            rate = rates[(entry.playCount * 3) % rates.count]
            // No two-octave drops. Combined with the floor in clampPitch,
            // phrases stay out of the sub-bass: down there a fragment stops
            // reading as a phrase and starts reading as a drone.
            octave = octaves[(entry.playCount * 5) % octaves.count]
        }

        let layerScale = 1.0 / (1.0 + 0.35 * Double(layers))
        // Presence is relative to the loudest phrase, for the same reason the
        // periods are: weight only ever decays, so judging level on the raw
        // number faded every phrase toward a third of its original volume over
        // a long session — which is what made the drone seem to grow louder and
        // louder underneath. Normalized, the material holds its level and only
        // its balance against the other phrases changes.
        let ceiling = max(0.001, entries.map(\.weight).max() ?? 1)
        let presence = 0.35 + 0.50 * (entry.weight / ceiling)
        let base = Float(layerScale * presence)

        var scheduled: [(time: Double, voicing: Voicing)] = []
        var lastEnd = time

        if arpeggiate {
            let steps = [0.5, 1.0 / 3.0, 0.25, 1.0 / 6.0, 0.75]
            let stepBeats = steps[(entry.playCount * 2) % steps.count]
            let ordered = notes.sorted { $0.pitch < $1.pitch }
            let pattern = (entry.playCount / max(1, entry.arpPrime)) % 4
            var sequence: [CapturedNote]
            switch pattern {
            case 0: sequence = ordered
            case 1: sequence = ordered.reversed()
            case 2: sequence = ordered + ordered.dropLast().reversed()
            default:
                // A wandering figure that keeps returning to the root.
                sequence = []
                var cursor = 0
                for i in 0..<(ordered.count * 2) {
                    sequence.append(ordered[cursor])
                    cursor = i % 3 == 2 ? 0 : (cursor + 1 + local.int(0..<2)) % ordered.count
                }
            }
            // One to three passes, sometimes climbing an octave.
            let passes = 1 + (entry.playCount / 2) % 3
            let climb = local.chance(0.4)
            var position = 0
            for pass in 0..<passes {
                for note in sequence {
                    let shift = octave + transpose + (climb ? 12 * pass : 0)
                    let pitch = clampPitch(note.pitch + shift)
                    let onset = time + Double(position) * stepBeats * spb
                    let hold = cappedHold(stepBeats * spb * (2.2 + 1.4 * local.unit()), pitch: pitch)
                    scheduled.append((onset, voicing(pitch: pitch,
                                                     velocity: note.velocity * base * 0.85,
                                                     hold: hold,
                                                     entry: entry,
                                                     index: position,
                                                     rng: &local)))
                    lastEnd = max(lastEnd, onset + hold)
                    position += 1
                }
            }
        } else {
            let source = reversed ? Array(notes.reversed()) : notes
            let span = notes.map(\.onsetBeats).max() ?? 0
            // Shuffling deals the pitches into different slots. Velocity and
            // duration stay with the slot, so the rhythm and its accents
            // survive intact and only the tune changes.
            var pitches = source.map(\.pitch)
            if shuffled { pitches = Self.dealt(pitches, rng: &local) }
            for (i, note) in source.enumerated() {
                let onsetBeats = reversed ? (span - note.onsetBeats) : note.onsetBeats
                let onset = time + onsetBeats * rate * spb
                let pitch = clampPitch(pitches[i] + transpose + octave)
                // Ambient: hold notes well past their played length.
                let hold = cappedHold(note.durationBeats * rate * spb * (1.5 + 1.2 * entry.weight),
                                      pitch: pitch)
                scheduled.append((onset, voicing(pitch: pitch,
                                                 velocity: note.velocity * base,
                                                 hold: hold,
                                                 entry: entry,
                                                 index: i,
                                                 rng: &local)))
                lastEnd = max(lastEnd, onset + hold)
            }
        }

        for item in scheduled { enqueue(.play(item.voicing), at: item.time) }

        if debugLogging {
            fireLog.append(FireLog(beat: beat, id: entry.phrase.id, prime: entry.period,
                                   camelot: Camelot(entry.phrase.key.transposed(by: transpose)).code,
                                   transpose: transpose, arpeggiated: arpeggiate,
                                   taped: tape, reversed: reversed, shuffled: shuffled,
                                   layers: layers, notes: scheduled.count,
                                   lowestPitch: scheduled.map(\.voicing.pitch).min() ?? 0,
                                   firstPitch: scheduled.first?.voicing.pitch ?? 0,
                                   lastPitch: scheduled.last?.voicing.pitch ?? 0,
                                   spanSeconds: (scheduled.map(\.time).max() ?? 0)
                                       - (scheduled.map(\.time).min() ?? 0),
                                   sourceFirstPitch: notes.first?.pitch ?? 0,
                                   sourceSpanBeats: (notes.map(\.onsetBeats).max() ?? 0)
                                       - (notes.map(\.onsetBeats).min() ?? 0),
                                   sourceOnsets: notes.map(\.onsetBeats),
                                   sourcePitches: notes.map(\.pitch),
                                   emittedOnsets: scheduled.map { $0.time - time },
                                   emittedPitches: scheduled.map(\.voicing.pitch),
                                   longestHold: scheduled.map(\.voicing.hold).max() ?? 0,
                                   longestBassHold: scheduled.filter { $0.voicing.pitch < 48 }
                                       .map(\.voicing.hold).max() ?? 0))
        }
        entry.playCount += 1
        entry.lastTranspose = transpose
        entry.lastArpeggiated = arpeggiate
        entry.lastTaped = tape
        entry.lastReversed = reversed
        entry.lastShuffled = shuffled
        entry.lastFragment = fragment
        entry.lastFiredBeat = beat
        entry.soundingUntil = lastEnd
        // Each airing costs a little presence, so phrases recede and newer
        // material comes forward.
        if !force { entry.weight = max(0.06, entry.weight * 0.975) }
        return true
    }

    /// Pan, timbre and the envelope only mean anything to the internal synth;
    /// over MIDI, pitch, velocity and length are all that survive.
    private func voicing(pitch: Int, velocity: Float, hold: Double, entry: VocabEntry,
                         index: Int, rng: inout Rng) -> Voicing {
        // Fan the notes of a phrase out around its own place in the field.
        let spread = Float(index % 2 == 0 ? 0.28 : -0.28) * Float(0.4 + rng.unit())
        return Voicing(pitch: pitch,
                       velocity: max(0.03, min(1.0, velocity)),
                       hold: hold,
                       pan: max(-1, min(1, entry.basePan + spread)),
                       timbre: Int32(entry.timbre),
                       // Long notes fade in; short ones speak.
                       attack: min(2.4, max(0.03, hold * (entry.timbre == 1 ? 0.02 : 0.28))),
                       release: min(9, max(0.6, hold * 1.1 + 1.4)),
                       part: .phrase)
    }

    private func maybeDrone(beat: Int, at time: Double) {
        // Echo answers; it does not start on its own. No vocabulary, no bed.
        guard !entries.isEmpty else { return }
        // A prime again, so the bed never lines up with the phrases above it.
        guard beat % 23 == 0 else { return }
        fireBed(at: time)
    }

    /// Stop the bed and start it again now, in whatever tone is selected.
    private func restartBed() {
        guard droneEnabled, !entries.isEmpty, playing else { return }
        releaseBed(at: currentTime)
        fireBed(at: currentTime)
    }

    private func releaseBed(at time: Double) {
        enqueue(.releaseVoice(id: Self.bedVoiceID), at: time)
        if bedRoute.toMIDI, let pitch = lastBedPitch {
            enqueue(.midiOff(pitch: pitch, channel: 1), at: time)
        }
        lastBedPitch = nil
    }

    private func fireBed(at time: Double) {
        droneCounter += 1
        let degrees = [0, 7, 0, 5, 7, 0]
        let degree = degrees[droneCounter % degrees.count]
        let pitch = clampPitch(36 + sessionKey.tonic + degree)
        lastBedPitch = pitch
        let bed = Voicing(id: Self.bedVoiceID,
                          pitch: pitch,
                          velocity: 0.17,
                          hold: 23 * spb * 0.8,
                          pan: droneCounter % 2 == 0 ? -0.2 : 0.2,
                          timbre: bedTimbre,
                          attack: 3.2,
                          release: 7.0,
                          part: .bed)
        enqueue(.play(bed), at: time)
    }

    private func enqueue(_ event: Event, at time: Double) {
        // Notes may be dropped under load; a note-off never can, or an external
        // instrument is left holding it forever.
        if case .play = event, pending.count > 900 { return }
        var i = pending.count
        while i > 0 && pending[i - 1].time > time { i -= 1 }
        pending.insert(Scheduled(time: time, event: event), at: i)
    }

    /// Fisher-Yates, then a guarantee that the result is actually a different
    /// order — a shuffle that happens to deal the notes back where they started
    /// is a silent no-op, and the badge would be lying.
    private static func dealt(_ pitches: [Int], rng: inout Rng) -> [Int] {
        guard pitches.count >= 2 else { return pitches }
        var out = pitches
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            let j = rng.int(0..<(i + 1))
            out.swapAt(i, j)
        }
        if out == pitches, let first = pitches.firstIndex(where: { $0 != pitches[0] }) {
            out.swapAt(0, first)
        }
        return out
    }

    /// Low notes get shorter holds. A bass note ringing for eight seconds while
    /// the music moves on above it stops sounding like part of a phrase and
    /// starts sounding like a drone.
    private func cappedHold(_ hold: Double, pitch: Int) -> Double {
        let ceiling: Double = pitch < 48 ? 3.0 : 14.0
        return min(ceiling, max(0.28, hold))
    }

    private func clampPitch(_ pitch: Int) -> Int {
        var p = pitch
        // C2. Below this a note is more rumble than pitch, especially held and
        // sent through the reverb.
        while p < 36 { p += 12 }
        while p > 100 { p -= 12 }
        return p
    }

    // MARK: - Snapshot

    private func publishSnapshot(now: Double) {
        var snap = WeaverSnapshot()
        snap.beat = beat
        snap.barPhase = spb > 0 ? min(1, max(0, 1 - (nextBeatTime - now) / spb)) : 0
        snap.sessionKey = sessionKey
        snap.sessionCamelot = Camelot(sessionKey).code
        snap.keyConfidence = sessionConfidence
        snap.voices = Int(synth.activeVoices)
        snap.hearingInput = listener.isHearingInput
        snap.notesInProgress = listener.noteCountInProgress
        snap.soundingCamelots = entries.filter { $0.soundingUntil > now }.map { $0.effectiveCamelot.code }
        if let learned = lastLearned, entries.contains(where: { $0.phrase.id == learned.id }) {
            snap.newest = LearnedPhrase(id: learned.id,
                                        ageSeconds: max(0, now - learned.at),
                                        reinforced: learned.reinforced)
        }

        snap.cards = entries.sorted { $0.weight > $1.weight }.map { entry in
            let period = max(1, entry.period)
            var until = ((entry.offset - beat) % period + period) % period
            if until == 0 { until = period }
            let notes = entry.phrase.notes
            let span = max(0.001, notes.map { $0.onsetBeats + $0.durationBeats }.max() ?? 1)
            let low = Double(notes.map(\.pitch).min() ?? 60)
            let high = Double(notes.map(\.pitch).max() ?? 72)
            let range = max(1.0, high - low)
            let lastSet = Set(entry.lastFragment)
            let glyph = notes.enumerated().map { (i, note) in
                GlyphDot(x: note.onsetBeats / span,
                         y: (Double(note.pitch) - low) / range,
                         on: lastSet.contains(i))
            }
            return PhraseCard(id: entry.phrase.id,
                              label: entry.phrase.label,
                              isChord: entry.phrase.isChord,
                              keyName: entry.phrase.key.transposed(by: entry.lastTranspose).name,
                              camelot: entry.effectiveCamelot.code,
                              prime: entry.period,
                              weight: entry.weight,
                              playCount: entry.playCount,
                              beatsUntilNext: until,
                              sounding: entry.soundingUntil > now,
                              transpose: entry.lastTranspose,
                              arpeggiated: entry.lastArpeggiated,
                              taped: entry.lastTaped,
                              reversed: entry.lastReversed,
                              shuffled: entry.lastShuffled,
                              isNewest: entry.phrase.id == lastLearned?.id,
                              glyph: glyph)
        }

        let payload = snap
        DispatchQueue.main.async { self.onSnapshot?(payload) }
    }

    /// Runs the beat logic on a synthetic clock, for offline analysis. Not
    /// used by the running app, which is driven by the timer in `start()`.
    /// `render` is handed the length of each beat, so a harness can pull the
    /// same number of audio samples the real clock would have and measure what
    /// actually comes out.
    func debugRun(beats: Int, render: ((Double) -> Void)? = nil) {
        for b in 0..<beats {
            beat = b
            let time = Double(b) * spb
            currentTime = time
            onBeat(b, at: time)
            if render != nil {
                // Commit everything due within this beat, then let the caller
                // render it.
                let end = time + spb
                while let first = pending.first, first.time <= end {
                    pending.removeFirst()
                    dispatch(first, at: first.time)
                }
                render?(spb)
            } else if pending.count > 400 {
                pending.removeAll()
            }
        }
    }

    func panic() {
        queue.async {
            self.pending.removeAll()
            self.synth.allNotesOff()
            self.midiOut?.allNotesOff()
        }
    }
}
