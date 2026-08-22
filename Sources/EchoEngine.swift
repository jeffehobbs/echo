import AppKit
import CoreMIDI
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Top-level app state: owns the audio output, the MIDI listener and the
/// weaver, and republishes the weaver's snapshots for SwiftUI.
@MainActor
final class EchoEngine: ObservableObject {
    @Published var snapshot = WeaverSnapshot()
    @Published var sources: [MIDISourceInfo] = []
    @Published var destinations: [MIDIDestinationInfo] = []
    /// Name of the session file in play, shown next to the vocabulary.
    @Published var sessionName: String?
    @Published var selectedDestination: MIDIUniqueID?

    /// Where the phrases go, and where the bed goes.
    @Published var phraseRoute: Route = .synth { didSet { weaver.phraseRoute = phraseRoute; save() } }
    @Published var bedRoute: Route = .synth { didSet { weaver.bedRoute = bedRoute; save() } }
    /// The bed's voice tone.
    @Published var bedTone: Timbre = Timbre.named(2) { didSet { weaver.bedTimbre = bedTone.index; save() } }

    @Published var bpm: Double = 58 { didSet { weaver.bpm = bpm; syncDelay(); save() } }
    @Published var density: Double = 0.5 { didSet { weaver.density = density; save() } }
    @Published var layers: Double = 4 { didSet { weaver.maxLayers = Int(layers); save() } }
    @Published var arpeggio: Double = 0.45 { didSet { weaver.arpeggioAmount = arpeggio; save() } }
    @Published var tape: Double = 0.30 { didSet { weaver.tapeAmount = tape; save() } }
    @Published var reverse: Double = 0.30 { didSet { weaver.reverseAmount = reverse; save() } }
    @Published var shuffle: Double = 0.25 { didSet { weaver.shuffleAmount = shuffle; save() } }
    @Published var harmonicPull: Double = 0.7 { didSet { weaver.harmonicPull = harmonicPull; save() } }
    @Published var reverb: Double = 58 { didSet { audio.reverbMix = Float(reverb); save() } }
    @Published var delay: Double = 28 { didSet { audio.delayMix = Float(delay); save() } }
    @Published var volume: Double = 0.85 { didSet { audio.kernel.masterVolume = Float(volume); save() } }

    @Published var playing = true { didSet { weaver.playing = playing; if !playing { weaver.panic() } } }
    @Published var learning = true { didSet { weaver.learning = learning } }
    @Published var monitorInput = false { didSet { weaver.monitorInput = monitorInput; save() } }
    @Published var drone = true { didSet { weaver.droneEnabled = drone; save() } }

    /// Settings are remembered between launches — an instrument that forgets
    /// its tempo and routing every time is annoying to play.
    private enum Key {
        static let bpm = "bpm", density = "density", layers = "layers"
        static let arpeggio = "arpeggio", harmonicPull = "harmonicPull"
        static let tape = "tape", reverse = "reverse", shuffle = "shuffle"
        static let reverb = "reverb", delay = "delay", volume = "volume"
        static let drone = "drone", monitor = "monitorInput"
        static let phraseRoute = "phraseRoute", bedRoute = "bedRoute"
        static let bedTone = "bedTone"
        static let destination = "destination"
    }

    private let defaults = UserDefaults.standard
    /// save() writes every key at once, so while load() is assigning the
    /// properties one by one it has to stay quiet — otherwise setting the first
    /// one writes the defaults back over everything still unread.
    private var isLoading = false

    private let audio = AudioOutput()
    private let midi = MIDIInput()
    private let midiOut = MIDIOutput()
    private let weaver: Weaver

    /// So the app delegate can hand over a session opened from the Finder.
    static weak var current: EchoEngine?

    init() {
        weaver = Weaver(synth: audio.kernel)
        weaver.onSnapshot = { [weak self] snap in
            MainActor.assumeIsolated { self?.snapshot = snap }
        }
        midi.onNoteOn = { [weak self] pitch, velocity, time in
            self?.weaver.noteOn(pitch: pitch, velocity: velocity, time: time)
        }
        midi.onNoteOff = { [weak self] pitch, time in
            self?.weaver.noteOff(pitch: pitch, time: time)
        }
        midi.onSustain = { [weak self] down in
            self?.weaver.setSustain(down)
        }
        midi.onAllNotesOff = { [weak self] in
            self?.weaver.inputAllNotesOff()
        }
        midi.onSourcesChanged = { [weak self] in
            self?.midi.connectAll()
            self?.refreshSources()
        }
        midiOut.onDestinationsChanged = { [weak self] in
            self?.refreshDestinations()
        }

        // Neither side may see the other's endpoints: listening to our own
        // output would make the vocabulary feed on itself, and sending to our
        // own input is an instant loop.
        midi.excluded = midiOut.ownUIDs
        midiOut.excluded = midi.ownUIDs
        weaver.midiOut = midiOut
        weaver.midiIn = midi

        load()
        sync()
        audio.start()
        weaver.start()
        midi.connectAll()
        refreshSources()
        refreshDestinations()
        syncDelay()
        EchoEngine.current = self

        // Never leave an external instrument holding a note.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.midiOut.allNotesOff() }
        }
    }

    func refreshSources() {
        sources = midi.availableSources()
    }

    func refreshDestinations() {
        destinations = midiOut.destinations()
        // A destination that disappeared should not stay selected.
        if let selected = selectedDestination, !destinations.contains(where: { $0.id == selected }) {
            select(destination: nil)
        }
    }

    func select(destination uid: MIDIUniqueID?) {
        midiOut.select(uid)
        selectedDestination = uid
        // Choosing a destination means you want to hear it: hand it the
        // phrases, and leave the bed where it is.
        if uid != nil, phraseRoute == .synth { phraseRoute = .midi }
        save()
    }

    func toggle(source: MIDISourceInfo) {
        midi.setConnected(!source.isConnected, uid: source.id)
        refreshSources()
    }

    func connectAll() {
        midi.connectAll()
        refreshSources()
    }

    func clearVocabulary() {
        weaver.clearVocabulary()
        weaver.panic()
    }

    func forget(_ id: Int) { weaver.forget(id: id) }
    func discardLastLearned() { weaver.forgetLastLearned() }
    func audition(_ id: Int) { weaver.audition(id: id) }
    func nudge(_ id: Int, by delta: Double) { weaver.nudge(id: id, by: delta) }
    func panic() { weaver.panic() }

    // MARK: - Sessions

    private var sessionType: UTType {
        UTType(EchoSession.typeIdentifier)
            ?? UTType(filenameExtension: EchoSession.fileExtension)
            ?? .json
    }

    private var controls: EchoSession.Controls {
        EchoSession.Controls(bpm: bpm, density: density, layers: layers,
                             arpeggio: arpeggio, tape: tape, reverse: reverse,
                             shuffle: shuffle, harmonicPull: harmonicPull,
                             reverb: reverb, delay: delay, volume: volume,
                             drone: drone, monitorInput: monitorInput,
                             learning: learning, playing: playing,
                             bedTone: Int(bedTone.index),
                             phraseRoute: phraseRoute.rawValue,
                             bedRoute: bedRoute.rawValue)
    }

    /// Freeze the session to a file: the vocabulary, where the weave had got
    /// to, and every control.
    func saveSession() {
        weaver.exportWeave { [weak self] weave in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [self.sessionType]
            panel.nameFieldStringValue = self.sessionName
                ?? "Session.\(EchoSession.fileExtension)"
            panel.title = "Save Session"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let session = EchoSession(controls: self.controls, weave: weave)
            do {
                try session.encoded().write(to: url, options: .atomic)
                self.sessionName = url.lastPathComponent
            } catch {
                self.report("Could not save the session", error)
            }
        }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [sessionType]
        panel.allowsMultipleSelection = false
        panel.title = "Open Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Also the path taken when a session is double-clicked in the Finder.
    func open(_ url: URL) {
        do {
            let session = try EchoSession.decoded(from: Data(contentsOf: url))
            apply(session)
            sessionName = url.lastPathComponent
        } catch {
            report("Could not open that session", error)
        }
    }

    /// Empty the vocabulary and forget the file, leaving the controls alone —
    /// they are how you like to work, not part of the piece.
    func newSession() {
        weaver.clearVocabulary()
        weaver.panic()
        sessionName = nil
    }

    private func apply(_ session: EchoSession) {
        let c = session.controls
        bpm = c.bpm
        density = c.density
        layers = c.layers
        arpeggio = c.arpeggio
        tape = c.tape
        reverse = c.reverse
        shuffle = c.shuffle
        harmonicPull = c.harmonicPull
        reverb = c.reverb
        delay = c.delay
        volume = c.volume
        drone = c.drone
        monitorInput = c.monitorInput
        learning = c.learning
        playing = c.playing
        bedTone = Timbre.named(Int32(c.bedTone))
        phraseRoute = Route(rawValue: c.phraseRoute) ?? phraseRoute
        bedRoute = Route(rawValue: c.bedRoute) ?? bedRoute
        sync()
        weaver.importWeave(session.weave)
    }

    private func report(_ message: String, _ error: Error) {
        NSLog("Echo: \(message): \(error)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Name of the current MIDI output target, for the header.
    var destinationLabel: String {
        guard let uid = selectedDestination,
              let match = destinations.first(where: { $0.id == uid }) else { return "Echo Out" }
        return match.name
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if defaults.object(forKey: Key.bpm) != nil {
            bpm = defaults.double(forKey: Key.bpm)
            density = defaults.double(forKey: Key.density)
            layers = defaults.double(forKey: Key.layers)
            arpeggio = defaults.double(forKey: Key.arpeggio)
            // Added after the first release, so they need their own defaults.
            if defaults.object(forKey: Key.tape) != nil { tape = defaults.double(forKey: Key.tape) }
            if defaults.object(forKey: Key.reverse) != nil { reverse = defaults.double(forKey: Key.reverse) }
            if defaults.object(forKey: Key.shuffle) != nil { shuffle = defaults.double(forKey: Key.shuffle) }
            harmonicPull = defaults.double(forKey: Key.harmonicPull)
            reverb = defaults.double(forKey: Key.reverb)
            delay = defaults.double(forKey: Key.delay)
            volume = defaults.double(forKey: Key.volume)
            drone = defaults.bool(forKey: Key.drone)
            monitorInput = defaults.bool(forKey: Key.monitor)
        }
        // Routing is readable on its own, so it can be set before first launch.
        if let raw = defaults.string(forKey: Key.phraseRoute), let route = Route(rawValue: raw) {
            phraseRoute = route
        }
        if let raw = defaults.string(forKey: Key.bedRoute), let route = Route(rawValue: raw) {
            bedRoute = route
        }
        if defaults.object(forKey: Key.bedTone) != nil {
            bedTone = Timbre.named(Int32(defaults.integer(forKey: Key.bedTone)))
        }
        let stored = defaults.integer(forKey: Key.destination)
        if stored != 0 {
            // Only reconnect if that endpoint is still around.
            let uid = MIDIUniqueID(stored)
            if midiOut.destinations().contains(where: { $0.id == uid }) {
                midiOut.select(uid)
                selectedDestination = uid
            }
        }
    }

    /// Push every setting into the weaver and the audio chain. `didSet` only
    /// fires for values that were actually stored, so without this the engine
    /// could quietly disagree with the interface.
    private func sync() {
        weaver.bpm = bpm
        weaver.density = density
        weaver.maxLayers = Int(layers)
        weaver.arpeggioAmount = arpeggio
        weaver.tapeAmount = tape
        weaver.reverseAmount = reverse
        weaver.shuffleAmount = shuffle
        weaver.harmonicPull = harmonicPull
        weaver.phraseRoute = phraseRoute
        weaver.bedRoute = bedRoute
        weaver.bedTimbre = bedTone.index
        weaver.droneEnabled = drone
        weaver.monitorInput = monitorInput
        weaver.playing = playing
        weaver.learning = learning
        audio.reverbMix = Float(reverb)
        audio.delayMix = Float(delay)
        audio.kernel.masterVolume = Float(volume)
        syncDelay()
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(bpm, forKey: Key.bpm)
        defaults.set(density, forKey: Key.density)
        defaults.set(layers, forKey: Key.layers)
        defaults.set(arpeggio, forKey: Key.arpeggio)
        defaults.set(tape, forKey: Key.tape)
        defaults.set(reverse, forKey: Key.reverse)
        defaults.set(shuffle, forKey: Key.shuffle)
        defaults.set(harmonicPull, forKey: Key.harmonicPull)
        defaults.set(reverb, forKey: Key.reverb)
        defaults.set(delay, forKey: Key.delay)
        defaults.set(volume, forKey: Key.volume)
        defaults.set(drone, forKey: Key.drone)
        defaults.set(monitorInput, forKey: Key.monitor)
        defaults.set(phraseRoute.rawValue, forKey: Key.phraseRoute)
        defaults.set(bedRoute.rawValue, forKey: Key.bedRoute)
        defaults.set(Int(bedTone.index), forKey: Key.bedTone)
        defaults.set(Int(selectedDestination ?? 0), forKey: Key.destination)
    }

    /// Keep the delay musical: a dotted quarter at the current tempo.
    private func syncDelay() {
        audio.delaySeconds = min(2.0, (60.0 / max(20, bpm)) * 1.5)
    }
}
