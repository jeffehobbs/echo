import Foundation

/// A frozen session: the vocabulary, where the weave had got to, and every
/// control. Reopening one puts Echo back exactly where it was left.
///
/// Timings are in beats, so a session keeps its feel at any tempo, and each
/// phrase stores its seed rather than the things derived from it — timbre,
/// stereo placement and the four manipulation primes all come out of that one
/// number, so a phrase reloaded next month behaves as it did when it was
/// played. The play counts travel too, which keeps each phrase where it was in
/// its own manipulation cycles rather than restarting them.
struct EchoSession: Codable {
    struct StoredNote: Codable {
        var pitch: Int
        var velocity: Float
        var onsetBeats: Double
        var durationBeats: Double
    }

    struct StoredPhrase: Codable {
        var id: Int
        var notes: [StoredNote]
        var isChord: Bool
        var tonic: Int
        var isMinor: Bool
        var keyConfidence: Double
        var label: String
        var weight: Double
        var seed: UInt32
        var playCount: Int
    }

    /// Everything the weaver itself holds.
    struct Weave: Codable {
        var beat: Int
        /// The rolling pitch-class histogram, so the session key carries on
        /// drifting from where it was rather than resetting.
        var histogram: [Double]
        var phrases: [StoredPhrase]
    }

    /// Every control, so a session sounds the way it did when it was saved.
    struct Controls: Codable {
        var bpm: Double
        var density: Double
        var layers: Double
        var arpeggio: Double
        var tape: Double
        var reverse: Double
        var shuffle: Double
        var harmonicPull: Double
        var reverb: Double
        var delay: Double
        var volume: Double
        var drone: Bool
        var monitorInput: Bool
        var learning: Bool
        var playing: Bool
        var bedTone: Int
        var phraseRoute: String
        var bedRoute: String
    }

    /// Bumped only for a change older readers could not survive.
    var version = 1
    var controls: Controls
    var weave: Weave

    static let fileExtension = "echo"
    static let typeIdentifier = "com.jeffhobbs.echo.session"

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> EchoSession {
        try JSONDecoder().decode(EchoSession.self, from: data)
    }
}

extension Phrase {
    init(stored: EchoSession.StoredPhrase) {
        self.init(id: stored.id,
                  notes: stored.notes.map {
                      CapturedNote(pitch: $0.pitch,
                                   velocity: $0.velocity,
                                   onsetBeats: $0.onsetBeats,
                                   durationBeats: $0.durationBeats)
                  },
                  isChord: stored.isChord,
                  key: MusicKey(tonic: stored.tonic, isMinor: stored.isMinor),
                  keyConfidence: stored.keyConfidence,
                  lengthBeats: stored.notes.map { $0.onsetBeats + $0.durationBeats }.max() ?? 1,
                  capturedAt: Clock.now(),
                  label: stored.label)
    }

    func stored(weight: Double, seed: UInt32, playCount: Int) -> EchoSession.StoredPhrase {
        EchoSession.StoredPhrase(id: id,
                                 notes: notes.map {
                                     EchoSession.StoredNote(pitch: $0.pitch,
                                                            velocity: $0.velocity,
                                                            onsetBeats: $0.onsetBeats,
                                                            durationBeats: $0.durationBeats)
                                 },
                                 isChord: isChord,
                                 tonic: key.tonic,
                                 isMinor: key.isMinor,
                                 keyConfidence: keyConfidence,
                                 label: label,
                                 weight: weight,
                                 seed: seed,
                                 playCount: playCount)
    }
}
