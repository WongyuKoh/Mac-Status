import SwiftUI

/// Draw tabs in SwiftUI, but let an AppKit button receive the entire tab's clicks.
struct EditorTabButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var isFocused = false

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(isSelected ? Palette.mint : Palette.muted)
            .background(isSelected ? Palette.mint.opacity(0.10) : (hovering ? Palette.raised : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? Palette.mint.opacity(0.75)
                                  : (isSelected ? Palette.mint.opacity(0.35) : .clear), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
            .overlay {
                NativeEditorTab(title: title, isSelected: isSelected, action: action,
                                onFocus: { isFocused = $0 })
            }
            .onHover { hovering = $0 }
    }
}

private struct NativeEditorTab: NSViewRepresentable {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    let onFocus: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> EditorTabControl { EditorTabControl(frame: .zero) }

    func updateNSView(_ button: EditorTabControl, context: Context) {
        button.setAccessibilityLabel(title)
        button.isTabSelected = isSelected
        button.isEnabled = isEnabled
        button.onActivate = action
        button.onFocus = onFocus
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorTabControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: proposal.height ?? 34)
    }
}

final class EditorTabControl: NSButton {
    var onActivate: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var isTabSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        setButtonType(.momentaryPushIn)
        isBordered = false
        isTransparent = true
        focusRingType = .none
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.radioButton)
        target = self
        action = #selector(activateTab)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? { isTabSelected ? 1 : 0 }

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

    @objc private func activateTab() { onActivate?() }
}
