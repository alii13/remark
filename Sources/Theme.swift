import SwiftUI

enum Ink {
    static let amber = Color(red: 0.909, green: 0.659, blue: 0.298)
    static let text  = Color(red: 0.957, green: 0.945, blue: 0.925)
    static let muted = Color(red: 0.561, green: 0.537, blue: 0.498)
    static let faint = Color(red: 0.361, green: 0.341, blue: 0.310)
    static let edge  = Color.white.opacity(0.09)
    static let backdrop = Color(red: 0.047, green: 0.047, blue: 0.051)
}

func geist(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
    Font.custom("Geist", size: size).weight(w)
}
func geistMono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
    .system(size: size, weight: w, design: .monospaced)
}

// The Remark mark: two amber quote strokes.
struct RemarkMark: View {
    var line: CGFloat = 6.5
    var color: Color = Ink.amber
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 64
            Path { p in
                p.move(to: CGPoint(x: 26*s, y: 22*s))
                p.addCurve(to: CGPoint(x: 22*s, y: 43*s), control1: CGPoint(x: 20*s, y: 28*s), control2: CGPoint(x: 19*s, y: 36*s))
                p.move(to: CGPoint(x: 42*s, y: 22*s))
                p.addCurve(to: CGPoint(x: 38*s, y: 43*s), control1: CGPoint(x: 36*s, y: 28*s), control2: CGPoint(x: 35*s, y: 36*s))
            }
            .stroke(color, style: StrokeStyle(lineWidth: line * s, lineCap: .round))
        }
    }
}

struct GlassBG: View {
    var radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(red: 0.075, green: 0.075, blue: 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 3)
    }
}

// A small live equalizer; animates when `active`.
struct Equalizer: View {
    var active: Bool
    @State private var phase = false
    let bars: [CGFloat] = [6, 13, 9, 5]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(bars.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Ink.amber.opacity(i == 3 ? 0.55 : 1))
                    .frame(width: 2, height: active && phase ? bars[i] : bars[i] * 0.5)
                    .animation(.easeInOut(duration: 0.4 + Double(i) * 0.1).repeatForever(autoreverses: true), value: phase)
            }
        }
        .frame(height: 14)
        .onAppear { phase = active }
        .onChange(of: active) { _, v in phase = v }
    }
}
