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
    /// Prime that gates arpeggios for this entry.
    var arpPrime: Int
    var lastTranspose = 0
    var lastArpeggiated = false
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
        self.arpPrime = [2, 3, 3, 5][rng.int(0..<4)]
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
        cmd.id = 0
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
    private var lastSnapshot: Double = 0

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
        var layers: Int
        var notes: Int
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

        // Which fragment: step through the list by a prime, so the sequence of
        // fragments visits all of them without ever cycling in step with the
        // phrase's own period.
        let step = Primes.step(for: entry.fragments.count, seed: Int(entry.seed % 97))
        let index = (entry.playCount * step) % entry.fragments.count
        var fragment = entry.fragments[index]
        if arpeggiate {
            // An arpeggio needs something to spread, so pass over the shell
            // and single-note fragments this time around.
            let spreadable = entry.fragments.filter { $0.count >= 3 }
            if !spreadable.isEmpty {
                fragment = spreadable[(entry.playCount * step) % spreadable.count]
            }
        }
        let notes = fragment.map { entry.phrase.notes[$0] }
        guard !notes.isEmpty else { return false }

        let transpose = chooseTranspose(for: entry, at: time)

        // Time and register transforms, also prime-stepped.
        let rates = [1.0, 1.0, 0.5, 2.0, 1.5, 2.0 / 3.0]
        let rate = rates[(entry.playCount * 3) % rates.count]
        let octaves = [0, 0, -12, 12, -12, -24]
        let octave = octaves[(entry.playCount * 5) % octaves.count]
        let reversed = !entry.phrase.isChord && entry.playCount % 7 == 6

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
                    let hold = max(0.28, stepBeats * spb * (2.2 + 1.4 * local.unit()))
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
            for (i, note) in source.enumerated() {
                let onsetBeats = reversed ? (span - note.onsetBeats) : note.onsetBeats
                let onset = time + onsetBeats * rate * spb
                // Ambient: hold notes well past their played length.
                var hold = note.durationBeats * rate * spb * (1.5 + 1.2 * entry.weight)
                hold = min(14, max(0.35, hold))
                let pitch = clampPitch(note.pitch + transpose + octave)
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
                                   layers: layers, notes: scheduled.count))
        }
        entry.playCount += 1
        entry.lastTranspose = transpose
        entry.lastArpeggiated = arpeggiate
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
        droneCounter += 1
        let degrees = [0, 7, 0, 5, 7, 0]
        let degree = degrees[droneCounter % degrees.count]
        let pitch = clampPitch(36 + sessionKey.tonic + degree)
        let bed = Voicing(pitch: pitch,
                          velocity: 0.17,
                          hold: 23 * spb * 0.8,
                          pan: droneCounter % 2 == 0 ? -0.2 : 0.2,
                          timbre: 2,
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

    private func clampPitch(_ pitch: Int) -> Int {
        var p = pitch
        while p < 24 { p += 12 }
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
