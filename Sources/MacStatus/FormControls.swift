import SwiftUI

struct StatusTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let error: String?
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "", error: String? = nil) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.error = error
    }

    var body: some View {
        StatusInputShell(title: title, isFocused: isFocused, error: error) {
            TextField(title, text: $text, prompt: Text(prompt).foregroundStyle(Palette.muted.opacity(0.75)))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .focusEffectDisabled()
                .autocorrectionDisabled()
                .accessibilityLabel(error == nil ? title : title + ", 확인 필요")
                .accessibilityHint(error ?? "")
        }
    }
}

struct StatusSecureField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let error: String?
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "", error: String? = nil) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.error = error
    }

    var body: some View {
        StatusInputShell(title: title, isFocused: isFocused, error: error) {
            SecureField(title, text: $text, prompt: Text(prompt).foregroundStyle(Palette.muted.opacity(0.75)))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .focusEffectDisabled()
                .autocorrectionDisabled()
                .accessibilityLabel(error == nil ? title : title + ", 확인 필요")
                .accessibilityHint(error ?? "")
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
    let error: String?
    let menuOptions: [StatusMenuOption]?

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], fallbackTitle: String = "선택",
         symbol: String = "list.bullet", tint: Color = Palette.mint, error: String? = nil,
         menuOptions: [StatusMenuOption]? = nil) {
        self.title = title
        self._selection = selection
        self.options = options
        self.fallbackTitle = fallbackTitle
        self.symbol = symbol
        self.tint = tint
        self.error = error
        self.menuOptions = menuOptions
    }

    private var selectedTitle: String {
        options.first(where: { $0.0 == selection })?.1 ?? fallbackTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Palette.muted)
                if error != nil {
                    Text("*")
                        .fontWeight(.bold)
                        .foregroundStyle(StatusInputFeedback.errorColor)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityHidden(true)
            StatusDropdown(title: selectedTitle, accessibilityTitle: error.map { title + ", 확인 필요: " + $0 } ?? title,
                           symbol: symbol, tint: tint,
                           options: styledOptions,
                           selectedIndex: options.firstIndex(where: { $0.0 == selection })) { index in
                selection = options[index].0
            }
            .overlay {
                if error != nil {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(StatusInputFeedback.errorColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StatusInputFeedback.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var styledOptions: [StatusMenuOption] {
        options.enumerated().map { index, option in
            let metadata = menuOptions.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            // Display metadata cannot change the binding's value-to-index map.
            return StatusMenuOption(title: option.1, symbol: metadata?.symbol ?? symbol, section: metadata?.section)
        }
    }
}

struct StatusMenuOption {
    let title: String
    var symbol: String? = nil
    var section: String? = nil
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

    func makeCoordinator() -> StatusMenuCoordinator { StatusMenuCoordinator() }

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
        return button
    }

    func updateNSView(_ button: StatusPopupButton, context: Context) {
        context.coordinator.update(button, configuration: .init(
            title: title, displayValue: displayValue, options: options, selectedIndex: selectedIndex,
            isActionMenu: isActionMenu, isEnabled: isEnabled, onSelect: onSelect, onFocus: onFocus
        ))
    }

    static func dismantleNSView(_ button: StatusPopupButton, coordinator: StatusMenuCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class StatusMenuCoordinator: NSObject, NSMenuDelegate {
    struct Configuration {
        let title: String
        let displayValue: String
        let options: [StatusMenuOption]
        let selectedIndex: Int?
        let isActionMenu: Bool
        let isEnabled: Bool
        let onSelect: (Int) -> Void
        let onFocus: (Bool) -> Void

        var signature: [String] {
            [title, isActionMenu ? "action" : "selection"]
                + options.map { $0.title + "\u{0}" + ($0.symbol ?? "") + "\u{0}" + ($0.section ?? "") }
        }
    }

    private weak var button: StatusPopupButton?
    private var installed: Configuration?
    private var pending: Configuration?
    private var trackingSnapshot: Configuration?
    private var installedSignature: [String] = []
    private var isTracking = false
    private var isClosing = false
    private var isDetached = false
    private var closeGeneration = 0

    func update(_ button: StatusPopupButton, configuration: Configuration) {
        guard !isDetached else { return }
        self.button = button
        // Changing even the selected index or callback while AppKit is tracking
        // can close the menu or map its old tags onto newly refreshed options.
        guard !isTracking && !isClosing else { pending = configuration; return }
        install(configuration, on: button)
    }

    private func install(_ configuration: Configuration, on button: StatusPopupButton) {
        installed = configuration
        button.target = self
        button.action = #selector(select(_:))
        button.onFocus = configuration.onFocus
        button.isEnabled = configuration.isEnabled
        button.pullsDown = configuration.isActionMenu
        button.setAccessibilityLabel(configuration.title)
        button.setAccessibilityValue(configuration.isActionMenu ? "" : configuration.displayValue)
        if installedSignature != configuration.signature {
            button.menu?.delegate = nil
            let menu = NSMenu(title: configuration.title)
            menu.autoenablesItems = false
            StatusMenuAppearance.configure(menu)
            menu.delegate = self
            if configuration.isActionMenu {
                let placeholder = NSMenuItem(title: configuration.title, action: nil, keyEquivalent: "")
                placeholder.tag = -1
                menu.addItem(placeholder)
            }
            var previousSection: String?
            for (index, option) in configuration.options.enumerated() {
                if let section = option.section, section != previousSection {
                    if index > 0 {
                        let separator = NSMenuItem.separator()
                        separator.tag = -2
                        separator.isEnabled = false
                        menu.addItem(separator)
                    }
                    let header = NSMenuItem.sectionHeader(title: section)
                    header.tag = -2
                    header.isEnabled = false
                    menu.addItem(header)
                }
                previousSection = option.section
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.tag = index
                menu.addItem(item)
            }
            button.menu = menu
            installedSignature = configuration.signature
        }
        if !configuration.isActionMenu {
            if let index = configuration.selectedIndex, configuration.options.indices.contains(index) {
                if button.selectedItem?.tag != index { button.selectItem(withTag: index) }
            } else { button.select(nil) }
        }
        for item in button.menu?.items ?? [] where configuration.options.indices.contains(item.tag) && !item.isSeparatorItem && !item.isSectionHeader {
            StatusMenuAppearance.configure(item, option: configuration.options[item.tag],
                                           isSelected: !configuration.isActionMenu && item.tag == configuration.selectedIndex)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !isDetached, button?.menu === menu else { return }
        closeGeneration += 1
        isClosing = false
        isTracking = true
        trackingSnapshot = installed
    }

    func menuDidClose(_ menu: NSMenu) {
        guard !isDetached, button?.menu === menu else { return }
        isTracking = false
        isClosing = true
        closeGeneration += 1
        let generation = closeGeneration
        // AppKit can close the menu before sending the popup button's action.
        // Keep its callback/indices until that action has run, and never change
        // menu structure from NSMenu's open/close delegate callbacks.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDetached, !self.isTracking,
                  self.closeGeneration == generation else { return }
            self.isClosing = false
            self.trackingSnapshot = nil
            if let latest = self.pending, let button = self.button {
                self.pending = nil
                self.install(latest, on: button)
            }
        }
    }

    @objc func select(_ sender: NSPopUpButton) {
        guard !isDetached, sender === button, let configuration = trackingSnapshot ?? installed,
              let selected = sender.selectedItem, configuration.options.indices.contains(selected.tag) else { return }
        configuration.onSelect(selected.tag)
    }

    func detach() {
        isDetached = true
        closeGeneration += 1
        let current = button
        current?.menu?.delegate = nil
        current?.target = nil
        current?.action = nil
        current?.onFocus = nil
        if isTracking { current?.menu?.cancelTrackingWithoutAnimation() }
        button = nil
        installed = nil
        pending = nil
        trackingSnapshot = nil
        isTracking = false
        isClosing = false
    }
}

final class StatusPopupButton: NSPopUpButton {
    var onFocus: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    var isInvalid = false
    var radius: CGFloat = 12

    private var borderColor: Color {
        if isInvalid { return StatusInputFeedback.errorColor }
        return isActive ? Palette.mint.opacity(0.7) : Color.white.opacity(isHovering ? 0.18 : 0.09)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [
                isActive || isHovering ? Palette.raised : Palette.raised.opacity(0.65),
                Palette.background.opacity(0.8)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
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
    let error: String?
    let content: Content
    @State private var hovering = false

    init(title: String, isFocused: Bool, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isFocused = isFocused
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(isFocused ? Palette.mint : Palette.muted)
                if error != nil {
                    Text("*")
                        .fontWeight(.bold)
                        .foregroundStyle(StatusInputFeedback.errorColor)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityHidden(true)
            content
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(StatusControlSurface(isActive: isFocused, isHovering: hovering, isInvalid: error != nil))
                .onHover { hovering = $0 }
            if let error {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StatusInputFeedback.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum StatusInputFeedback {
    static let errorColor = Color(hex: 0xF78282)
}
