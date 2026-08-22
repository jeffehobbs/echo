import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: EchoEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                leftColumn
                Rectangle().fill(Theme.hairline).frame(width: 1)
                vocabulary
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("echo")
                .font(.system(size: 22, weight: .ultraLight, design: .default))
                .tracking(6)
                .foregroundStyle(Theme.text)
            Spacer()
            inputIndicator
            sourcesMenu
            destinationsMenu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var inputIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.snapshot.hearingInput ? Theme.accent : Theme.faint)
                .frame(width: 6, height: 6)
            Theme.label(engine.snapshot.hearingInput
                        ? "hearing \(engine.snapshot.notesInProgress)"
                        : "waiting")
        }
        .animation(.easeOut(duration: 0.15), value: engine.snapshot.hearingInput)
    }

    private var sourcesMenu: some View {
        Menu {
            Button("Listen to All Sources") { engine.connectAll() }
            Divider()
            if engine.sources.isEmpty {
                Text("No MIDI sources found")
            }
            ForEach(engine.sources) { source in
                Button {
                    engine.toggle(source: source)
                } label: {
                    Label(source.name, systemImage: source.isConnected ? "checkmark" : "")
                }
            }
            Divider()
            Text("Echo (virtual destination) \u{00B7} always on")
        } label: {
            // The virtual "Echo" destination always counts as an input.
            let count = engine.sources.filter(\.isConnected).count + 1
            Text("MIDI IN \u{00B7} \(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Theme.dim)
        .onAppear { engine.refreshSources() }
    }

    private var destinationsMenu: some View {
        Menu {
            Button {
                engine.select(destination: nil)
            } label: {
                Label("Echo Out only (apps subscribe to it)",
                      systemImage: engine.selectedDestination == nil ? "checkmark" : "")
            }
            if !engine.destinations.isEmpty { Divider() }
            ForEach(engine.destinations) { destination in
                Button {
                    engine.select(destination: destination.id)
                } label: {
                    Label(destination.name,
                          systemImage: engine.selectedDestination == destination.id ? "checkmark" : "")
                }
            }
        } label: {
            Text("MIDI OUT \u{00B7} \(engine.destinationLabel)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(engine.phraseRoute.toMIDI || engine.bedRoute.toMIDI ? Theme.accent.opacity(0.85) : Theme.dim)
        .onAppear { engine.refreshDestinations() }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            CamelotWheelView(sessionKey: engine.snapshot.sessionKey,
                             confidence: engine.snapshot.keyConfidence,
                             cards: engine.snapshot.cards,
                             beatPhase: engine.snapshot.barPhase)
                .frame(height: 232)
                .padding(.horizontal, 6)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(Int(engine.bpm.rounded()))")
                    .font(.system(size: 40, weight: .ultraLight, design: .default))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Theme.label("bpm")
                    Text("beat \(engine.snapshot.beat)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
            }

            VStack(spacing: 9) {
                Dial(title: "tempo", value: $engine.bpm, range: 30...120,
                     readout: "\(Int(engine.bpm.rounded()))", step: 1)
                Dial(title: "density", value: $engine.density, range: 0...1,
                     readout: percent(engine.density))
                Dial(title: "layers", value: $engine.layers, range: 1...8,
                     readout: "\(Int(engine.layers))", step: 1)
                Dial(title: "harmonic pull", value: $engine.harmonicPull, range: 0...1,
                     readout: percent(engine.harmonicPull))

                // The three ways a phrase can be turned over, side by side:
                // they are siblings, and it reads better than three more rows.
                VStack(alignment: .leading, spacing: 6) {
                    Theme.label("manipulations")
                    HStack(spacing: 14) {
                        Dial(title: "arp", value: $engine.arpeggio, range: 0...1,
                             readout: percent(engine.arpeggio))
                        Dial(title: "tape", value: $engine.tape, range: 0...1,
                             readout: percent(engine.tape))
                    }
                    HStack(spacing: 14) {
                        Dial(title: "rev", value: $engine.reverse, range: 0...1,
                             readout: percent(engine.reverse))
                        Dial(title: "shuffle", value: $engine.shuffle, range: 0...1,
                             readout: percent(engine.shuffle))
                    }
                }
                .padding(.top, 3)
            }

            VStack(spacing: 7) {
                Segmented(title: "phrases", options: Route.allCases,
                          label: { $0.label }, selection: $engine.phraseRoute)
                Segmented(title: "bed", options: Route.allCases,
                          label: { $0.label }, selection: $engine.bedRoute)
                Segmented(title: "tone", options: Timbre.all,
                          label: { $0.name }, selection: $engine.bedTone)
                    .disabled(!engine.drone)
                    .opacity(engine.drone ? 1 : 0.4)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 300)
    }

    // MARK: - Vocabulary

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let name = engine.sessionName {
                    Theme.label("\(name) \u{00B7} \(engine.snapshot.cards.count) phrases")
                } else {
                    Theme.label("vocabulary \u{00B7} \(engine.snapshot.cards.count) phrases")
                }
                Spacer()
                if !engine.snapshot.soundingCamelots.isEmpty {
                    Text(engine.snapshot.soundingCamelots.joined(separator: " + "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if let newest = engine.snapshot.newest,
               let card = engine.snapshot.cards.first(where: { $0.id == newest.id }) {
                LearnedBanner(card: card, learned: newest) { engine.discardLastLearned() }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }

            if engine.snapshot.cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.snapshot.cards) { card in
                            PhraseRow(card: card)
                                .environmentObject(engine)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("play something")
                .font(.system(size: 15, weight: .thin))
                .tracking(2)
                .foregroundStyle(Theme.dim)
            Text("Echo commits a phrase after you rest for a moment.\nChords, lines, single notes \u{2014} all of it becomes material.")
                .font(.system(size: 10, weight: .light))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.faint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Pill(title: "play", isOn: $engine.playing)
            Pill(title: "learn", isOn: $engine.learning)
            Pill(title: "monitor", isOn: $engine.monitorInput)
            Pill(title: "drone", isOn: $engine.drone)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 16)
            HStack(spacing: 14) {
                miniDial("reverb", $engine.reverb, 0...100)
                miniDial("delay", $engine.delay, 0...100)
                miniDial("level", $engine.volume, 0...1)
            }
            Spacer()
            Text("\(engine.snapshot.voices) voices")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.faint)
            FlatButton(title: "silence") { engine.panic() }
            FlatButton(title: "clear") { engine.clearVocabulary() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func miniDial(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Theme.label(title)
            Slider(value: value, in: range)
                .frame(width: 62)
                .controlSize(.mini)
                .tint(Theme.accent.opacity(0.7))
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// The last thing Echo heard, with a way to throw it away. Sitting above a list
/// sorted by weight, this is the only place the newest phrase is guaranteed to
/// be — and a bad phrase wants discarding immediately, not hunting for.
struct LearnedBanner: View {
    let card: PhraseCard
    let learned: LearnedPhrase
    let discard: () -> Void

    private var age: String {
        let seconds = Int(learned.ageSeconds.rounded())
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    var body: some View {
        HStack(spacing: 12) {
            PhraseGlyph(card: card)
                .frame(width: 60, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(learned.reinforced ? "HEARD AGAIN" : "JUST LEARNED")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.warm)
                    Text(age)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
                HStack(spacing: 7) {
                    Text(card.label)
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(Theme.text)
                    Text(card.camelot)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                    Text("every \(card.prime) beats")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }

            Spacer()

            Button(action: discard) {
                HStack(spacing: 5) {
                    Text("DISCARD")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.4)
                    Text("\u{2318}\u{232B}")
                        .font(.system(size: 9))
                        .opacity(0.55)
                }
                .foregroundStyle(Theme.warm)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.warm.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Forget this phrase")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.warm.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.warm.opacity(0.22), lineWidth: 0.7))
        )
    }
}

/// One phrase in the vocabulary: its shape, where it sits on the wheel, the
/// prime it recurs on, and how present it currently is.
struct PhraseRow: View {
    let card: PhraseCard
    @EnvironmentObject private var engine: EchoEngine

    var body: some View {
        HStack(spacing: 12) {
            PhraseGlyph(card: card)
                .frame(width: 84, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.label)
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(card.sounding ? Theme.accent : Theme.text)
                    if card.isChord {
                        Theme.label("chord")
                    }
                    if card.sounding {
                        if card.arpeggiated { badge("arp") }
                        if card.taped != 0 { badge(card.taped < 0 ? "tape \u{2193}" : "tape \u{2191}") }
                        if card.reversed { badge("rev") }
                        if card.shuffled { badge("shuf") }
                    }
                }
                HStack(spacing: 8) {
                    Text(card.camelot)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                    Text(card.keyName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                    if card.transpose != 0 {
                        Text(card.transpose > 0 ? "+\(card.transpose)" : "\(card.transpose)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.warm.opacity(0.8))
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("every \(card.prime) beats")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text(card.sounding ? "sounding" : "in \(card.beatsUntilNext)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(card.sounding ? Theme.accent : Theme.faint)
            }

            VStack(alignment: .trailing, spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(width: 46, height: 3)
                    Capsule().fill(Theme.accent.opacity(0.75))
                        .frame(width: 46 * max(0.03, min(1, card.weight)), height: 3)
                }
                Text("\(card.playCount)\u{00D7}")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: 3) {
                stepper("minus", -0.12)
                stepper("plus", 0.12)
                Button { engine.forget(card.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(card.sounding ? Theme.accent.opacity(0.05) : Color.clear)
        .overlay(alignment: .leading) {
            // A hairline on the newest phrase, so the banner above and the row
            // below are obviously the same thing.
            if card.isNewest {
                Rectangle().fill(Theme.warm.opacity(0.7)).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.audition(card.id) }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.warm)
    }

    private func stepper(_ symbol: String, _ delta: Double) -> some View {
        Button { engine.nudge(card.id, by: delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

/// Piano-roll thumbnail of a phrase. Notes in the fragment Echo played last
/// time are lit; the rest sit in the dark.
struct PhraseGlyph: View {
    let card: PhraseCard

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 3
            let w = size.width - inset * 2
            let h = size.height - inset * 2
            guard !card.glyph.isEmpty else { return }
            for note in card.glyph {
                let x = inset + CGFloat(note.x) * w
                let y = inset + CGFloat(1 - note.y) * h
                let r: CGFloat = note.on ? 2.6 : 1.8
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                let color = note.on
                    ? (card.sounding ? Theme.accent : Theme.accent.opacity(0.55))
                    : Theme.faint
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }
}
