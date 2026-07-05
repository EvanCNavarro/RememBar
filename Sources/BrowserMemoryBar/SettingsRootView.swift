import SwiftUI

/// The root of RememBar's settings window: a toolbar-style tab bar over the selected tab's content.
/// Hosted in a real titled `NSWindow` (`SettingsWindowController`) — a normal window whose text
/// fields focus reliably. New settings categories are added by extending `SettingsTab`; the tab bar
/// and switcher pick them up automatically.
struct SettingsRootView: View {
    let catalog: AliasCatalog
    var onCheckForUpdates: (() -> Void)?
    var onUninstall: (() -> Void)?

    @StateObject private var familiesModel: AliasEditorModel
    @State private var tab: SettingsTab = .termFamilies

    init(catalog: AliasCatalog, onCheckForUpdates: (() -> Void)? = nil, onUninstall: (() -> Void)? = nil) {
        self.catalog = catalog
        self.onCheckForUpdates = onCheckForUpdates
        self.onUninstall = onUninstall
        _familiesModel = StateObject(wrappedValue: AliasEditorModel(catalog: catalog))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Tokens.line)
            content
                // Width fills; height fits the CURRENT tab's content (no maxHeight:.infinity — that made
                // NSHostingView size the window to ~screen height, leaving the short About tab with a huge
                // vertical void). The window now sizes per tab, like macOS System Settings.
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Tokens.panel)
    }

    private var tabBar: some View {
        HStack(spacing: Tokens.space) {
            ForEach(SettingsTab.allCases) { candidate in
                SettingsTabButton(tab: candidate, isSelected: tab == candidate) { tab = candidate }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.micro + 2)
        .padding(.horizontal, Tokens.space)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .termFamilies:
            AliasEditorView(model: familiesModel)
        case .about:
            AboutTab(onCheckForUpdates: onCheckForUpdates, onUninstall: onUninstall)
        }
    }
}

/// The settings categories. Add a case (plus its `content` branch above) to grow the window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case termFamilies
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .termFamilies: return "Term Families"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .termFamilies: return "tag"
        case .about: return "info.circle"
        }
    }
}

/// A toolbar-style tab: icon over label, highlighted when selected — matches the macOS preferences
/// toolbar feel in RememBar's dark palette.
private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    private var tint: Color { isSelected ? Tokens.accent : (hovered ? Tokens.text : Tokens.muted) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(width: 74, height: 40)
            .background(
                RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                    .fill(isSelected ? Tokens.row : (hovered ? Tokens.row.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
