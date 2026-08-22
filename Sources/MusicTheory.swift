import Foundation

// MARK: - Keys

/// A key center: tonic pitch class (0 = C) plus mode.
struct MusicKey: Equatable, Hashable {
    var tonic: Int       // 0-11, 0 = C
    var isMinor: Bool

    static let noteNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    var name: String { "\(MusicKey.noteNames[((tonic % 12) + 12) % 12]) \(isMinor ? "min" : "maj")" }

    /// Semitones to move `self` onto `other`, folded into -6...5 so phrases
    /// stay near the register they were played in.
    func shift(to other: MusicKey) -> Int {
        var d = (other.tonic - tonic) % 12
        if d > 5 { d -= 12 }
        if d < -6 { d += 12 }
        return d
    }

    func transposed(by semitones: Int) -> MusicKey {
        MusicKey(tonic: (((tonic + semitones) % 12) + 12) % 12, isMinor: isMinor)
    }
}

// MARK: - Camelot wheel

/// Position on the Camelot (harmonic mixing) wheel: 1-12 plus A (minor) or
/// B (major). C major is 8B, A minor is 8A; +1 on the wheel is a fifth up.
struct Camelot: Equatable, Hashable {
    var number: Int      // 1-12
    var isMinor: Bool

    var code: String { "\(number)\(isMinor ? "A" : "B")" }

    init(number: Int, isMinor: Bool) {
        self.number = ((number - 1) % 12 + 12) % 12 + 1
        self.isMinor = isMinor
    }

    init(_ key: MusicKey) {
        // Steps up the circle of fifths from C, since 7 * 7 == 1 (mod 12).
        let relativeMajorTonic = key.isMinor ? (key.tonic + 3) % 12 : key.tonic
        let fifths = (7 * relativeMajorTonic) % 12
        self.number = (7 + fifths) % 12 + 1
        self.isMinor = key.isMinor
    }

    /// The key this wheel slot represents.
    var key: MusicKey {
        // Invert Camelot(_:): number -> fifths -> relative major tonic.
        let fifths = ((number - 1) - 7 + 24) % 12
        let majorTonic = (7 * fifths) % 12
        return MusicKey(tonic: isMinor ? (majorTonic + 9) % 12 : majorTonic, isMinor: isMinor)
    }

    /// Shortest distance around the 12-slot ring.
    func ringDistance(to other: Camelot) -> Int {
        let d = abs(number - other.number) % 12
        return min(d, 12 - d)
    }

    /// How well two slots stack, 0...1. Classic harmonic-mixing rules:
    /// same slot best, relative major/minor next, then a fifth either way.
    func compatibility(with other: Camelot) -> Double {
        let d = ringDistance(to: other)
        if d == 0 { return isMinor == other.isMinor ? 1.0 : 0.90 }
        if d == 1 { return isMinor == other.isMinor ? 0.85 : 0.50 }
        if d == 2 { return isMinor == other.isMinor ? 0.42 : 0.22 }
        if d == 3 { return isMinor == other.isMinor ? 0.22 : 0.12 }
        return 0.08
    }

    /// All 24 slots, wheel order, for the UI.
    static let all: [Camelot] = (1...12).flatMap { n in
        [Camelot(number: n, isMinor: true), Camelot(number: n, isMinor: false)]
    }
}

// MARK: - Key detection

/// Krumhansl-Kessler key finding over a duration-weighted pitch-class
/// histogram. Cheap, and stable enough on a handful of notes.
enum KeyFinder {
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Returns the best key plus a 0...1 confidence, or nil if the histogram
    /// is empty.
    static func detect(_ histogram: [Double]) -> (key: MusicKey, confidence: Double)? {
        let total = histogram.reduce(0, +)
        guard histogram.count == 12, total > 0 else { return nil }

        var best: (MusicKey, Double)?
        var second = -2.0
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minorProfile : majorProfile
                var rotated = [Double](repeating: 0, count: 12)
                for i in 0..<12 { rotated[i] = profile[(i - tonic + 12) % 12] }
                let r = correlation(histogram, rotated)
                if best == nil || r > best!.1 {
                    second = best?.1 ?? second
                    best = (MusicKey(tonic: tonic, isMinor: isMinor), r)
                } else if r > second {
                    second = r
                }
            }
        }
        guard let (key, r) = best else { return nil }
        // Confidence blends absolute fit with the margin over the runner-up.
        let margin = max(0, r - second)
        return (key, min(1, max(0, r * 0.7 + margin * 3.0)))
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return 0 }
        return num / (da * db).squareRoot()
    }
}

// MARK: - Chords

/// Names a simultaneity for display. Only the shapes that show up when
/// somebody noodles on a pad controller.
enum ChordNamer {
    private static let shapes: [(name: String, intervals: [Int])] = [
        ("", [0, 4, 7]), ("m", [0, 3, 7]), ("dim", [0, 3, 6]), ("aug", [0, 4, 8]),
        ("sus2", [0, 2, 7]), ("sus4", [0, 5, 7]), ("5", [0, 7]),
        ("maj7", [0, 4, 7, 11]), ("7", [0, 4, 7, 10]), ("m7", [0, 3, 7, 10]),
        ("m7b5", [0, 3, 6, 10]), ("dim7", [0, 3, 6, 9]), ("6", [0, 4, 7, 9]),
        ("m6", [0, 3, 7, 9]), ("add9", [0, 2, 4, 7]), ("m9", [0, 3, 7, 10, 14 % 12]),
        ("maj9", [0, 2, 4, 7, 11]),
    ]

    /// A named chord, which also gives us a far better key center than a
    /// profile match on three notes can.
    struct Identity {
        var root: Int
        var quality: String

        private static let minorQualities: Set<String> = ["m", "m7", "m7b5", "dim", "dim7", "m6", "m9"]

        var name: String { MusicKey.noteNames[root] + quality }
        var isMinorTonality: Bool { Identity.minorQualities.contains(quality) }
        var key: MusicKey { MusicKey(tonic: root, isMinor: isMinorTonality) }
    }

    /// The bass note gets first refusal on being the root, so an A-C-E-G
    /// voicing reads as Am7 rather than C6 — which puts it on the right slot
    /// of the wheel.
    static func identify(_ pitches: [Int]) -> Identity? {
        let classes = Set(pitches.map { (($0 % 12) + 12) % 12 })
        guard classes.count >= 2 else { return nil }
        let bass = (((pitches.min() ?? 0) % 12) + 12) % 12
        let order = [bass] + (0..<12).filter { $0 != bass }
        for root in order where classes.contains(root) {
            let rel = Set(classes.map { (($0 - root) + 12) % 12 })
            for shape in shapes where Set(shape.intervals.map { $0 % 12 }) == rel {
                return Identity(root: root, quality: shape.name)
            }
        }
        return nil
    }

    static func name(for pitches: [Int]) -> String {
        let classes = Set(pitches.map { (($0 % 12) + 12) % 12 })
        guard !classes.isEmpty else { return "-" }
        if classes.count == 1 { return MusicKey.noteNames[classes.first!] }
        if let identity = identify(pitches) { return identity.name }
        // Unnamed stack: show it as its lowest note plus a count.
        let low = pitches.min() ?? 0
        return "\(MusicKey.noteNames[((low % 12) + 12) % 12])(\(classes.count))"
    }
}

// MARK: - Pitch helpers

enum Pitch {
    static func frequency(_ midi: Int) -> Double {
        440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    static func name(_ midi: Int) -> String {
        let pc = ((midi % 12) + 12) % 12
        return "\(MusicKey.noteNames[pc])\(midi / 12 - 1)"
    }
}
