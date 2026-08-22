import SwiftUI

/// The Camelot wheel: 12 numbered slots, minor on the inner ring, major on the
/// outer. Brightness is compatibility with the session key, and every phrase in
/// the vocabulary sits as a dot on the slot it currently occupies — so you can
/// see Echo keeping its layers in neighboring keys.
///
/// Split into layers on purpose: snapshots land ten times a second, and only
/// the beat ring genuinely changes that often. Giving each layer the narrowest
/// possible input lets SwiftUI skip the rest.
struct CamelotWheelView: View {
    let sessionKey: MusicKey
    let confidence: Double
    let cards: [PhraseCard]
    let beatPhase: Double

    var body: some View {
        ZStack {
            WheelRings(session: Camelot(sessionKey))
            WheelLabels()
            PhraseDots(cards: cards)
            BeatRing(phase: beatPhase)
            hub
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var hub: some View {
        VStack(spacing: 1) {
            Text(Camelot(sessionKey).code)
                .font(.system(size: 26, weight: .thin, design: .monospaced))
                .foregroundStyle(Theme.text)
            Text(sessionKey.name)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Theme.dim)
            Capsule()
                .fill(Theme.accent.opacity(0.7))
                .frame(width: 22 * max(0.12, min(1, confidence)), height: 1.5)
                .padding(.top, 3)
        }
    }
}

/// Geometry shared by every layer of the wheel.
private enum Wheel {
    static let gap = (Double.pi / 12) * 0.10

    static func angle(_ slot: Camelot) -> Double {
        Double(slot.number - 1) / 12 * 2 * .pi - .pi / 2
    }

    static func radii(_ slot: Camelot, _ radius: Double) -> (inner: Double, outer: Double) {
        slot.isMinor ? (radius * 0.34, radius * 0.62) : (radius * 0.66, radius * 0.96)
    }
}

/// Redraws only when the session key moves.
private struct WheelRings: View {
    let session: Camelot

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for slot in Camelot.all {
                let mid = Wheel.angle(slot)
                let (inner, outer) = Wheel.radii(slot, radius)
                var path = Path()
                path.addArc(center: center, radius: outer,
                            startAngle: .radians(mid - .pi / 12 + Wheel.gap),
                            endAngle: .radians(mid + .pi / 12 - Wheel.gap), clockwise: false)
                path.addArc(center: center, radius: inner,
                            startAngle: .radians(mid + .pi / 12 - Wheel.gap),
                            endAngle: .radians(mid - .pi / 12 + Wheel.gap), clockwise: true)
                path.closeSubpath()

                if slot == session {
                    context.fill(path, with: .color(Theme.accent.opacity(0.55)))
                } else {
                    // Compatible keys glow; distant ones stay nearly black.
                    let fit = session.compatibility(with: slot)
                    context.fill(path, with: .color(Theme.accent.opacity(0.035 + 0.22 * fit * fit)))
                }
                context.stroke(path, with: .color(Color.white.opacity(slot == session ? 0.30 : 0.05)),
                               lineWidth: 0.6)
            }
        }
    }
}

/// No inputs at all, so these twenty-four text draws happen once.
private struct WheelLabels: View {
    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for slot in Camelot.all {
                let mid = Wheel.angle(slot)
                let (inner, outer) = Wheel.radii(slot, radius)
                let point = CGPoint(x: center.x + cos(mid) * (inner + outer) / 2,
                                    y: center.y + sin(mid) * (inner + outer) / 2)
                context.draw(
                    Text(slot.code)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8)),
                    at: point)
            }
        }
    }
}

/// One dot per phrase, fanned along its slot's arc: inside the minor ring,
/// outside the major one.
private struct PhraseDots: View {
    let cards: [PhraseCard]

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var perSlot: [String: Int] = [:]
            for card in cards {
                guard let slot = Camelot.all.first(where: { $0.code == card.camelot }) else { continue }
                let index = perSlot[card.camelot, default: 0]
                perSlot[card.camelot] = index + 1
                let fan = (Double(index % 5) - 2) * 0.028
                let mid = Wheel.angle(slot) + fan
                let ring = slot.isMinor ? radius * 0.30 : radius * 1.02
                let point = CGPoint(x: center.x + cos(mid) * ring, y: center.y + sin(mid) * ring)
                let r = 1.6 + card.weight * 3.0
                let dot = Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                let color = card.sounding ? (card.arpeggiated ? Theme.warm : Theme.accent) : Theme.faint
                context.fill(dot, with: .color(color.opacity(card.sounding ? 0.95 : 0.45)))
            }
        }
    }
}

/// The only layer that really changes ten times a second: one arc.
private struct BeatRing: View {
    let phase: Double

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 * 0.26
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The faint full circle makes the swept arc read as a gauge around
            // the hub rather than a stray tick above the key name.
            let track = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
            context.stroke(track, with: .color(Color.white.opacity(0.07)), lineWidth: 1.2)
            var path = Path()
            path.addArc(center: center, radius: radius,
                        startAngle: .radians(-.pi / 2),
                        endAngle: .radians(-.pi / 2 + phase * 2 * .pi), clockwise: false)
            context.stroke(path, with: .color(Theme.accent.opacity(0.55)), lineWidth: 1.2)
        }
    }
}
