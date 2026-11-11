import AppKit
import Foundation

extension AccountSwitcherPanelView {

    func buildRouteBBody(into body: NSView, theme: PanelTheme) -> CGFloat {
        var y: CGFloat = 0
        let banner = TileView(frame: NSRect(x: inset, y: y, width: contentWidth, height: 64), fill: theme.tint(.indigo), border: theme.color(.indigo).withAlphaComponent(0.35))
        banner.place(makeLabel("Secondary lane only", size: 12.5, weight: .semibold, color: theme.text(.indigo)), x: 12, y: 10, width: contentWidth - 24)
        banner.place(makeLabel("No requests or keys in this preview. Native Codex stays the", size: 11, color: theme.secondaryText), x: 12, y: 28, width: contentWidth - 24)
        banner.place(makeLabel("default for sends, uploads, accounts and live operations.", size: 11, color: theme.secondaryText), x: 12, y: 43, width: contentWidth - 24)
        body.addSubview(banner)
        y = banner.frame.maxY + 12

        for profile in state.routeBProfiles {
            let isSelected = profile.id == state.selectedRouteBProfileID
            let capabilities = routeBCapabilities(profile.capabilities, width: contentWidth - 24, theme: theme)
            let tile = TileView(
                frame: NSRect(x: inset, y: y, width: contentWidth, height: 78 + capabilities.height + 12),
                fill: theme.tileFill,
                border: isSelected ? theme.color(.green).withAlphaComponent(0.5) : theme.tileBorder,
                borderWidth: isSelected ? 1 : 0.5
            )
            let button = GlassButton(title: isSelected ? "Selected" : "Select", style: isSelected ? .secondary : .primary, theme: theme) { [weak self] in
                self?.actions.selectRouteBProfile(profile.id)
            }
            button.isEnabled = !isSelected
            let buttonX = contentWidth - 12 - button.frame.width
            tile.place(button, x: buttonX, y: 12)
            tile.place(makeLabel(profile.name, size: 13, weight: .semibold, color: theme.primaryText), x: 12, y: 12, width: buttonX - 20)
            tile.place(makeLabel("\(profile.provider) · \(profile.model)", size: 11, color: theme.secondaryText), x: 12, y: 30, width: buttonX - 20)
            tile.place(makeLabel(profile.summary, size: 11, color: theme.secondaryText), x: 12, y: 50, width: contentWidth - 24)

            for badge in capabilities.badges {
                tile.place(badge.view, x: 12 + badge.origin.x, y: 76 + badge.origin.y)
            }
            body.addSubview(tile)
            y = tile.frame.maxY + 10
        }
        return y + 2
    }

    private func routeBCapabilities(_ capabilities: [RouteBCapability], width: CGFloat, theme: PanelTheme)
        -> (badges: [(view: CapsuleTagView, origin: NSPoint)], height: CGFloat) {
        var badges: [(view: CapsuleTagView, origin: NSPoint)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for capability in capabilities {
            let (tone, symbol): (PanelTheme.Tone, String)
            switch capability.state {
            case .ready: (tone, symbol) = (.green, "✓")
            case .testRequired: (tone, symbol) = (.orange, "!")
            case .blocked: (tone, symbol) = (.red, "×")
            }
            let badge = CapsuleTagView(text: "\(symbol) \(capability.label)", theme: theme,
                                       foreground: theme.text(tone), background: theme.tint(tone), height: 20, fontSize: 10.5)
            if x > 0, x + badge.frame.width > width {
                x = 0
                y += 26
            }
            badges.append((badge, NSPoint(x: x, y: y)))
            x += badge.frame.width + 6
        }
        return (badges, badges.isEmpty ? 0 : y + 26)
    }
}
