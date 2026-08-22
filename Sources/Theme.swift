import SwiftUI

/// One place for the palette and type, so the whole app reads as a single
/// quiet surface rather than a stack of controls.
enum Theme {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let panel = Color(red: 0.071, green: 0.082, blue: 0.098)
    static let hairline = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.88)
    static let dim = Color.white.opacity(0.42)
    static let faint = Color.white.opacity(0.22)
    static let accent = Color(red: 0.50, green: 0.85, blue: 0.79)
    static let warm = Color(red: 0.89, green: 0.72, blue: 0.53)

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium, design: .default))
            .tracking(1.7)
            .foregroundStyle(Theme.dim)
    }
}

/// Compact labeled slider used throughout the control columns.
struct Dial: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var readout: String
    var step: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Theme.label(title)
                Spacer()
                Text(readout)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
            if step > 0 {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
        .tint(Theme.accent.opacity(0.75))
        .controlSize(.mini)
    }
}

/// Flat toggle pill; on-state carries the accent so the running state of the
/// app is readable at a glance.
struct Pill: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(isOn ? Theme.background : Theme.dim)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? Theme.accent.opacity(0.85) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Three-way routing selector, styled like the rest of the controls.
struct Segmented<T: Hashable & Identifiable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 8) {
            Theme.label(title)
            Spacer()
            HStack(spacing: 2) {
                ForEach(options) { option in
                    let isOn = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(label(option).uppercased())
                            .font(.system(size: 8, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(isOn ? Theme.background : Theme.dim)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isOn ? Theme.accent.opacity(0.85) : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct FlatButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}
