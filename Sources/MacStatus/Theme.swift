import SwiftUI

enum Palette {
    static let background = Color(hex: 0x121517)
    static let surface = Color(hex: 0x1B1F22)
    static let raised = Color(hex: 0x23282C)
    static let line = Color.white.opacity(0.08)
    static let text = Color(hex: 0xF2F4F4)
    static let muted = Color(hex: 0x929B9F)
    static let mint = Color(hex: 0xA8EAC5)

    static func tint(_ name: String) -> Color {
        switch name {
        case "orange": return Color(hex: 0xE8AC8C)
        case "blue": return Color(hex: 0x95BDF5)
        case "purple": return Color(hex: 0xBAA8EB)
        case "yellow": return Color(hex: 0xE4D091)
        default: return mint
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

extension View {
    func cardSurface(radius: CGFloat = 14) -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Palette.line, lineWidth: 1))
    }
}

struct QuietIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Palette.text : Palette.muted)
                .frame(width: 29, height: 29)
                .background(hovering ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

struct AccentButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.background)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Palette.mint, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

enum MetricFormat {
    static func number(_ value: Double, unit: String) -> String {
        if unit == "tokens" {
            if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
            if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        }
        if unit == "USD" { return String(format: "$%.2f", value) }
        if unit == "%" || unit == "°C" { return String(format: "%.0f", value) }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
    static func value(_ reading: MetricReading, template: MetricTemplate) -> String {
        if let text = reading.text { return text }
        guard let value = reading.value else { return "—" }
        return number(value, unit: template.unit)
    }
    static func reset(_ date: Date) -> String {
        if date <= Date() { return "갱신 대기" }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds > 86400 { return "\(seconds / 86400)일 \((seconds % 86400) / 3600)시간 후 초기화" }
        if seconds > 3600 { return "\(seconds / 3600)시간 \((seconds % 3600) / 60)분 후 초기화" }
        return "\(max(1, seconds / 60))분 후 초기화"
    }
}

struct UsageBar: View {
    let fraction: Double?
    let tint: Color
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                if let fraction {
                    Capsule().fill(fraction >= 0.9 ? Palette.tint("orange") : tint)
                        .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
                }
            }
        }.frame(height: height)
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let lower = min(values.min() ?? 0, 0)
                let upper = max(values.max() ?? 1, lower + 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: geo.size.width * Double(index) / Double(values.count - 1), y: geo.size.height * (1 - (value - lower) / (upper - lower)))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(tint.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
