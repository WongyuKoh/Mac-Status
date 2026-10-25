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
    let symbol: String
    let tint: Color

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], fallbackTitle: String = "선택",
         symbol: String = "list.bullet", tint: Color = Palette.mint) {
        self.title = title
        self._selection = selection
        self.options = options
        self.fallbackTitle = fallbackTitle
        self.symbol = symbol
        self.tint = tint
    }

    private var selectedTitle: String {
        options.first(where: { $0.0 == selection })?.1 ?? fallbackTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            StatusDropdown(title: selectedTitle, accessibilityTitle: title, symbol: symbol, tint: tint,
                           options: options.map { StatusMenuOption(title: $0.1) },
                           selectedIndex: options.firstIndex(where: { $0.0 == selection })) { index in
                selection = options[index].0
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusMenuOption {
    let title: String
    var symbol: String? = nil
}

/// A full-size native popup button keeps menu, keyboard, and accessibility behavior
/// while the SwiftUI background remains visible underneath it.
struct StatusDropdown: View {
    let title: String
    let accessibilityTitle: String
    let symbol: String
    var tint: Color = Palette.mint
    let options: [StatusMenuOption]
    var selectedIndex: Int? = nil
    var isActionMenu = false
    var expands = true
    let onSelect: (Int) -> Void
    @State private var isFocused = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering || isFocused ? tint : Palette.muted)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.04), in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.leading, 7).padding(.trailing, 9)
        .frame(minHeight: 38)
        .background(StatusControlSurface(isActive: isFocused, isHovering: hovering))
        .accessibilityHidden(true)
        .overlay {
            StatusNativeMenu(title: accessibilityTitle, displayValue: title, options: options, selectedIndex: selectedIndex,
                             isActionMenu: isActionMenu,
                             onSelect: onSelect, onFocus: { isFocused = $0 })
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private struct StatusNativeMenu: NSViewRepresentable {
    let title: String
    let displayValue: String
    let options: [StatusMenuOption]
    let selectedIndex: Int?
    let isActionMenu: Bool
    let onSelect: (Int) -> Void
    let onFocus: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusPopupButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: proposal.height ?? 38)
    }

    func makeNSView(context: Context) -> StatusPopupButton {
        let button = StatusPopupButton(frame: .zero, pullsDown: isActionMenu)
        button.isTransparent = true
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.focusRingType = .none
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        return button
    }

    func updateNSView(_ button: StatusPopupButton, context: Context) {
        context.coordinator.onSelect = onSelect
        button.onFocus = onFocus
        button.isEnabled = isEnabled
        button.pullsDown = isActionMenu
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(isActionMenu ? "" : displayValue)
        context.coordinator.optionCount = options.count
        let signature = [isActionMenu ? "action" : "selection"] + options.map { $0.title + "\u{0}" + ($0.symbol ?? "") }
        if context.coordinator.optionSignature != signature {
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            if isActionMenu {
                let placeholder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                placeholder.tag = -1
                menu.addItem(placeholder)
            }
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.tag = index
                if let symbol = option.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            }
            button.menu = menu
            context.coordinator.optionSignature = signature
        }
        if !isActionMenu, let selectedIndex {
            if button.indexOfSelectedItem != selectedIndex { button.selectItem(at: selectedIndex) }
        } else if !isActionMenu { button.select(nil) }
    }

    final class Coordinator: NSObject {
        var optionSignature: [String] = []
        var optionCount = 0
        var onSelect: ((Int) -> Void)?
        @objc func select(_ sender: NSPopUpButton) {
            guard let selected = sender.selectedItem, (0..<optionCount).contains(selected.tag) else { return }
            onSelect?(selected.tag)
        }
    }
}

private final class StatusPopupButton: NSPopUpButton {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }
}

struct StatusSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Palette.text : Palette.muted)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(StatusControlSurface(isActive: configuration.isPressed, isHovering: hovering))
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

/// An inset surface shared by text fields and menu triggers. Decorations never intercept input.
struct StatusControlSurface: View {
    var isActive = false
    var isHovering = false
    var radius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [
                isActive || isHovering ? Palette.raised : Palette.raised.opacity(0.65),
                Palette.background.opacity(0.8)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isActive ? Palette.mint.opacity(0.7) : Color.white.opacity(isHovering ? 0.18 : 0.09), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius - 1, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.04), .clear],
                                                 startPoint: .top, endPoint: .center), lineWidth: 1)
                    .padding(1)
            }
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
            .allowsHitTesting(false)
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
                .foregroundStyle(isFocused ? Palette.mint : Palette.muted)
                .accessibilityHidden(true)
            content
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(StatusControlSurface(isActive: isFocused, isHovering: hovering))
                .onHover { hovering = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
