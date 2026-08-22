import Foundation

/// One note inside a captured phrase. Timing is stored in beats (at the BPM
/// in force when it was played), so changing the tempo later re-times the
/// whole vocabulary instead of stretching audio.
struct CapturedNote {
    var pitch: Int
    var velocity: Float
    var onsetBeats: Double
    var durationBeats: Double
}

/// A phrase the listener heard: either a simultaneity (chord) or a line.
struct Phrase: Identifiable {
    let id: Int
    var notes: [CapturedNote]
    var isChord: Bool
    var key: MusicKey
    var keyConfidence: Double
    var lengthBeats: Double
    var capturedAt: Double
    var label: String

    var camelot: Camelot { Camelot(key) }
    var lowestPitch: Int { notes.map(\.pitch).min() ?? 60 }
    var highestPitch: Int { notes.map(\.pitch).max() ?? 60 }
    var averageVelocity: Float {
        guard !notes.isEmpty else { return 0.5 }
        return notes.map(\.velocity).reduce(0, +) / Float(notes.count)
    }

    /// Transposition-invariant shape, used to recognize the same phrase played
    /// again. Chords compare as stacked intervals (voicing order in the
    /// capture buffer is not meaningful); lines compare in the order played.
    var shape: [Int] {
        guard !notes.isEmpty else { return [] }
        if isChord {
            let sorted = notes.map(\.pitch).sorted()
            return sorted.map { $0 - sorted[0] }
        }
        let root = notes[0].pitch
        return notes.map { $0.pitch - root }
    }

    /// Duration-weighted pitch-class histogram, used for key finding here and
    /// for the rolling session key in the weaver.
    static func histogram(_ notes: [CapturedNote]) -> [Double] {
        var h = [Double](repeating: 0, count: 12)
        for n in notes {
            let weight = max(0.05, n.durationBeats) * Double(0.4 + n.velocity)
            h[((n.pitch % 12) + 12) % 12] += weight
        }
        return h
    }
}

/// Turns live MIDI into phrases. A phrase closes when nothing is held and the
/// player has been quiet for `gapSeconds`.
final class PhraseListener {
    /// Silence that ends a phrase.
    var gapSeconds: Double = 1.4
    /// Hard caps so a held drone or a long noodle still gets committed.
    var maxLengthSeconds: Double = 14
    var maxNotes = 32
    /// Beats per second at capture time, kept in sync with the transport.
    var bpm: Double = 60

    var onPhrase: ((Phrase) -> Void)?

    private struct OpenNote {
        var start: Double
        var velocity: Float
    }

    private var open: [Int: OpenNote] = [:]
    private var pending: [(pitch: Int, velocity: Float, start: Double, end: Double)] = []
    private var phraseStart: Double = 0
    private var lastActivity: Double = 0
    private var sustained = false
    private var heldBySustain: Set<Int> = []
    private var nextID = 1

    var isHearingInput: Bool { !open.isEmpty }
    var noteCountInProgress: Int { pending.count + open.count }

    func noteOn(pitch: Int, velocity: Float, time: Double) {
        if pending.isEmpty && open.isEmpty { phraseStart = time }
        heldBySustain.remove(pitch)
        open[pitch] = OpenNote(start: time, velocity: velocity)
        lastActivity = time
        if pending.count + open.count >= maxNotes { closeIfReady(now: time, force: true) }
    }

    func noteOff(pitch: Int, time: Double) {
        if sustained {
            heldBySustain.insert(pitch)
            // Releasing a key is still playing, pedal or not.
            lastActivity = time
            return
        }
        finish(pitch: pitch, time: time)
    }

    func setSustain(_ down: Bool, time: Double) {
        sustained = down
        if !down {
            for pitch in heldBySustain { finish(pitch: pitch, time: time) }
            heldBySustain.removeAll()
        }
    }

    private func finish(pitch: Int, time: Double) {
        guard let note = open.removeValue(forKey: pitch) else { return }
        pending.append((pitch, note.velocity, note.start, max(time, note.start + 0.03)))
        lastActivity = time
    }

    /// Called from the weaver tick. Commits a phrase once the player rests.
    func tick(now: Double) {
        closeIfReady(now: now, force: false)
    }

    private func closeIfReady(now: Double, force: Bool) {
        // Held notes count as content too: with the pedal down nothing has
        // been released yet, so `pending` is still empty.
        guard !pending.isEmpty || !open.isEmpty else { return }
        // Resting ends a phrase whether or not the pedal is still down: with
        // sustain held, the notes go on ringing but the gesture is over. (This
        // also means a controller that latches CC 64 cannot wedge capture.)
        let quiet = (open.isEmpty || sustained) && (now - lastActivity) >= gapSeconds
        let tooLong = (now - phraseStart) >= maxLengthSeconds
        guard force || quiet || tooLong else { return }

        // Anything still held gets committed at its current length.
        for (pitch, note) in open {
            pending.append((pitch, note.velocity, note.start, max(now, note.start + 0.03)))
        }
        open.removeAll()
        heldBySustain.removeAll()

        let captured = pending.sorted { $0.start < $1.start }
        pending.removeAll()
        guard captured.count >= 1 else { return }

        let spb = 60.0 / max(20, bpm)
        let origin = captured[0].start
        let notes = captured.map {
            CapturedNote(pitch: $0.pitch,
                         velocity: $0.velocity,
                         onsetBeats: ($0.start - origin) / spb,
                         durationBeats: max(0.05, ($0.end - $0.start) / spb))
        }

        let spread = (notes.last?.onsetBeats ?? 0) * spb
        let isChord = notes.count >= 2 && spread < 0.11
        let detected = KeyFinder.detect(Phrase.histogram(notes))
        let pitchClass = ((notes[0].pitch % 12) + 12) % 12
        var key = detected?.key ?? MusicKey(tonic: pitchClass, isMinor: false)
        var confidence = detected?.confidence ?? 0.1
        let label: String

        if isChord, let identity = ChordNamer.identify(notes.map(\.pitch)) {
            label = identity.name
            // Trust the chord's own root over the profile match, and take the
            // two agreeing as strong evidence.
            key = identity.key
            confidence = detected?.key == identity.key ? min(1, confidence + 0.25) : 0.7
        } else if notes.count == 1 {
            label = Pitch.name(notes[0].pitch)
            key = MusicKey(tonic: pitchClass, isMinor: false)
            confidence = 0.15
        } else if isChord {
            label = ChordNamer.name(for: notes.map(\.pitch))
        } else {
            label = "\(notes.count) notes"
        }

        let phrase = Phrase(id: nextID,
                            notes: notes,
                            isChord: isChord,
                            key: key,
                            keyConfidence: confidence,
                            lengthBeats: notes.map { $0.onsetBeats + $0.durationBeats }.max() ?? 1,
                            capturedAt: now,
                            label: label)
        nextID += 1
        onPhrase?(phrase)
    }

    /// Everything goes: a panic from the controller, or the user clearing out.
    func allNotesOff(time: Double) {
        sustained = false
        for pitch in open.keys { finish(pitch: pitch, time: time) }
        heldBySustain.removeAll()
    }

    func reset() {
        open.removeAll()
        pending.removeAll()
        heldBySustain.removeAll()
    }
}

/// Breaks phrases into the small pieces Echo actually plays back. Fragments
/// are index lists into the phrase's notes, so no note data is duplicated.
enum Fragmenter {
    static func fragments(for phrase: Phrase) -> [[Int]] {
        let n = phrase.notes.count
        guard n > 0 else { return [] }
        var out: [[Int]] = [Array(0..<n)]
        if n == 1 { return out }

        if phrase.isChord {
            let byPitch = (0..<n).sorted { phrase.notes[$0].pitch < phrase.notes[$1].pitch }
            out.append([byPitch[0], byPitch[n - 1]])                    // shell
            if n >= 3 {
                out.append(Array(byPitch.prefix(2)))                    // bottom
                out.append(Array(byPitch.suffix(2)))                    // top
                out.append([byPitch[0]] + byPitch.suffix(max(1, n - 2)))  // drop the inner voice
            }
            for i in byPitch { out.append([i]) }                        // single tones
        } else {
            // Contiguous motifs of every useful length, at every start.
            for length in 2...min(5, n) {
                for start in 0...(n - length) {
                    out.append(Array(start..<(start + length)))
                }
            }
            // Thinned readings: take every 2nd and every 3rd note.
            for stride in [2, 3] where n > stride {
                out.append(Array(Swift.stride(from: 0, to: n, by: stride)))
            }
            out.append(Array((n - min(3, n))..<n))                      // tail motif
            for i in 0..<n where phrase.notes[i].velocity > phrase.averageVelocity {
                out.append([i])                                         // accented single notes
            }
        }

        // Deduplicate, keep the order stable, and cap the list.
        var seen = Set<[Int]>()
        var unique: [[Int]] = []
        for f in out where !f.isEmpty && !seen.contains(f) {
            seen.insert(f)
            unique.append(f)
        }
        return Array(unique.prefix(18))
    }
}
