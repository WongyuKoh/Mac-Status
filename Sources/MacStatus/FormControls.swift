import SwiftUI

struct StatusTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "") {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        StatusInputShell(title: title, isFocused: isFocused) {
            TextField(title, text: $text, prompt: Text(prompt).foregroundStyle(Palette.muted.opacity(0.75)))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .focusEffectDisabled()
                .autocorrectionDisabled()
                .accessibilityLabel(title)
        }
    }
}

struct StatusSecureField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "") {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        StatusInputShell(title: title, isFocused: isFocused) {
            SecureField(title, text: $text, prompt: Text(prompt).foregroundStyle(Palette.muted.opacity(0.75)))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .focusEffectDisabled()
                .autocorrectionDisabled()
                .accessibilityLabel(title)
        }
    }
}

struct StatusMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    let fallbackTitle: String
    @FocusState private var isFocused: Bool

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], fallbackTitle: String = "선택") {
        self.title = title
        self._selection = selection
        self.options = options
        self.fallbackTitle = fallbackTitle
    }

    private var selectedTitle: String {
        options.first(where: { $0.0 == selection })?.1 ?? fallbackTitle
    }

    var body: some View {
        StatusInputShell(title: title, isFocused: isFocused) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].1).tag(options[index].0)
                    }
                }.pickerStyle(.inline)
            } label: {
                Text(selectedTitle)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .buttonStyle(.plain)
            .focused($isFocused)
            .focusEffectDisabled()
            .accessibilityLabel(title)
            .accessibilityValue(selectedTitle)
        }
    }
}

/// The shell handles appearance while the native controls keep text editing,
/// selection, keyboard shortcuts, secure entry, and accessibility behavior.
private struct StatusInputShell<Content: View>: View {
    let title: String
    let isFocused: Bool
    let content: Content
    @State private var hovering = false

    init(title: String, isFocused: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isFocused = isFocused
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            content
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(isFocused || hovering ? Palette.raised : Palette.surface,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? Palette.mint.opacity(0.75) : (hovering ? Palette.muted.opacity(0.35) : Color.white.opacity(0.12)),
                                  lineWidth: isFocused ? 1.5 : 1))
                .onHover { hovering = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusSourceSelector: View {
    @Binding var selection: MetricKind

    var body: some View {
        HStack(spacing: 4) {
            StatusSourceOption(kind: .http, isSelected: selection == .http) { selection = .http }
            StatusSourceOption(kind: .manual, isSelected: selection == .manual) { selection = .manual }
        }
        .padding(3)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("데이터 소스")
    }
}

private struct StatusSourceOption: View {
    let kind: MetricKind
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: kind == .http ? "network" : "square.and.pencil")
                    .accessibilityHidden(true)
                Text(kind == .http ? "HTTP JSON API" : "직접 입력")
                    .lineLimit(1)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Palette.mint : (hovering || isFocused ? Palette.text : Palette.muted))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(isSelected ? Palette.mint.opacity(0.10) : (hovering || isFocused ? Palette.raised : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Palette.mint.opacity(0.75) : (isSelected ? Palette.mint.opacity(0.35) : .clear), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(kind == .http ? "HTTP JSON API" : "직접 입력")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(kind == .http ? "API에서 값을 자동으로 읽습니다." : "직접 입력한 값을 표시합니다.")
    }
}
