import SwiftUI

/// Keep AppKit's menu tracking, keyboard navigation, and accessibility while
/// giving every dropdown the app's typography, symbols, and selection accent.
@MainActor
enum StatusMenuAppearance {
    static func configure(_ menu: NSMenu) {
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.font = .systemFont(ofSize: 13)
        menu.minimumWidth = 200
        menu.allowsContextMenuPlugIns = false
    }

    static func configure(_ item: NSMenuItem, option: StatusMenuOption, isSelected: Bool) {
        item.attributedTitle = NSAttributedString(string: option.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? NSColor(Palette.mint) : NSColor.labelColor
        ])
        item.image = symbol(option.symbol ?? "circle", color: NSColor(Palette.mint).withAlphaComponent(isSelected ? 1 : 0.8))
        item.onStateImage = symbol("checkmark.circle.fill", color: NSColor(Palette.mint))
        item.state = isSelected ? .on : .off
        item.toolTip = option.title
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        let size = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(size.applying(palette))
        image?.isTemplate = false
        image?.size = NSSize(width: 15, height: 15)
        return image
    }
}
