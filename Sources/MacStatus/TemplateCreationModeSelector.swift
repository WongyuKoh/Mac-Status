import SwiftUI

enum TemplateCreationMode: Int, CaseIterable, Identifiable {
    case presets, ai, json

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .presets: return "프리셋 · 직접 만들기"
        case .ai: return "AI로 템플릿 만들기"
        case .json: return "JSON 가져오기"
        }
    }

    var subtitle: String {
        switch self {
        case .presets: return "기본 항목으로 빠르게 시작"
        case .ai: return "원하는 통계를 말로 설명"
        case .json: return "기존 템플릿을 붙여넣기"
        }
    }

    var symbol: String {
        switch self {
        case .presets: return "square.grid.2x2"
        case .ai: return "sparkles"
        case .json: return "curlybraces"
        }
    }

    var tint: Color {
        switch self {
        case .presets: return Palette.mint
        case .ai: return Palette.tint("purple")
        case .json: return Palette.tint("blue")
        }
    }
}

struct TemplateCreationModeSelector: View {
    @Binding var selection: TemplateCreationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("만들기 방식")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
            HStack(alignment: .top, spacing: 10) {
                ForEach(TemplateCreationMode.allCases) { mode in
                    CreationModeButton(mode: mode, isSelected: selection == mode) {
                        selection = mode
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("만들기 방식")
    }
}

private struct CreationModeButton: View {
    let mode: TemplateCreationMode
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? Palette.mint : mode.tint)
                        .frame(width: 34, height: 34)
                        .background((isSelected ? Palette.mint : mode.tint).opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 10))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.mint)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(mode.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(mode.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(isSelected ? Palette.mint.opacity(hovering ? 0.10 : 0.06) : (hovering ? Palette.raised : Palette.surface),
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(isSelected ? Palette.mint.opacity(0.65) : (hovering ? Palette.muted.opacity(0.35) : Palette.line), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
