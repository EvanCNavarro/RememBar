import MacFaceKit
import SwiftUI

// RememBar's update-flow dialogs. Every state is one `UpdateDialog`: the icon never resizes, the
// header / sub-header / button row hold their size and place, and only the middle (release notes or
// a progress bar) changes — so the flow morphs smoothly instead of jumping between bespoke layouts.
// Driven by RememBarUserDriver; the same view backs the dev gallery. Sparkle still performs the
// security-critical work; this only presents it and relays the user's choice.

let updateWindowBG = Color(red: 0.157, green: 0.157, blue: 0.169)
private let dialogWidth: CGFloat = 400
private let singleButtonWidth: CGFloat = 184
private let noteGlyphSlot: CGFloat = 16   // shared column for the "What's new?" chevron + bullets

// MARK: - Primitives

/// One action button — primary (blue) or secondary (outlined), optional leading SF Symbol. Either a
/// fixed width, or `fillWidth` to split a spanning pair. Hover brightens.
struct UpdateActionButton: View {
    let title: String
    var systemImage: String?
    var primary: Bool = false
    var width: CGFloat?
    var fillWidth: Bool = false
    let action: () -> Void
    @State private var hovered = false

    private static let horizontalPadding = Tokens.space + Tokens.micro
    private static let iconTextGap = (Tokens.space + Tokens.micro) / 2

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.iconTextGap) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: primary ? .semibold : .medium))
            }
            .foregroundStyle(primary ? .white : Tokens.text)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: width)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(primary ? Tokens.accent : (hovered ? Tokens.rowActive : Tokens.row))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(primary ? .clear : (hovered ? Tokens.lineStrong : Tokens.line), lineWidth: 1)
            )
            .brightness(hovered && primary ? 0.06 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Determinate / indeterminate progress bar. `fraction == nil` renders a fixed partial bar.
struct UpdateProgressBar: View {
    var fraction: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.row)
                Capsule().fill(Tokens.accent).frame(width: max(0, geo.size.width * (fraction ?? 0.35)))
            }
        }
        .frame(height: 6)
    }
}

/// Expandable (default-expanded) "What's new?" with structured, staggered items.
struct ReleaseNotesSection: View {
    let items: [String]
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Clickable header spanning the box — the chevron sits in the same leading column as the
            // bullets below, and "What's new?" aligns with the item text.
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { expanded.toggle() }
            } label: {
                HStack(spacing: Tokens.space) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: noteGlyphSlot, alignment: .center)
                    Text("What's new?").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Tokens.space + Tokens.micro)
                .padding(.vertical, Tokens.space + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(Tokens.line)
                notesContent
            }
        }
        .background(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous).fill(Tokens.field))
        .overlay(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous).stroke(Tokens.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }

    /// The item list. Inline when it fits; a fixed-height scroll once there are enough items to
    /// overflow, so a long release can't grow the dialog off-screen.
    @ViewBuilder private var notesContent: some View {
        let list = VStack(alignment: .leading, spacing: Tokens.space) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                NoteItemRow(text: item, index: index)
            }
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(maxWidth: .infinity, alignment: .leading)

        if items.count > 5 {
            ScrollView { list }.frame(height: 176)
        } else {
            list
        }
    }
}

/// A release-note item that springs up + fades in, staggered by position (the result-row spring).
private struct NoteItemRow: View {
    let text: String
    let index: Int
    @State private var shown = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.space) {
            Circle().fill(Tokens.accent).frame(width: 5, height: 5)
                .frame(width: noteGlyphSlot, alignment: .center)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 9)
        .onAppear {
            guard !shown else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78).delay(0.05 + Double(index) * 0.07)) {
                shown = true
            }
        }
    }
}

// MARK: - The one dialog

/// Every update state is this dialog with different content. Fixed icon, consistent header/sub-header
/// typography, one bottom button row (single button = modest centered; a pair spans). Only `middle`
/// changes between states.
struct UpdateDialog: View {
    struct Action {
        let title: String
        var icon: String?
        let run: () -> Void
    }
    enum Middle {
        case none
        case notes([String])
        case progress(Double?)
    }

    let header: String
    var badge: String?
    var subheader: String?
    var middle: Middle = .none
    var notesExpanded: Binding<Bool> = .constant(true)
    var primary: Action?
    var secondary: Action?

    var body: some View {
        VStack(spacing: Tokens.space + Tokens.micro) {
            AppIconView(bundledImage: Bundle.packagedResourceURL("RememBarAppIcon", withExtension: "png")
                .flatMap(NSImage.init(contentsOf:)))
                .frame(width: 56, height: 56)

            VStack(spacing: Tokens.micro) {
                HStack(spacing: Tokens.micro + 1) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.accent)
                    }
                    Text(header)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let subheader {
                    Text(subheader)
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            middleView
            buttonRow
        }
        .padding(Tokens.space + Tokens.micro + 4)
        .frame(width: dialogWidth)
    }

    @ViewBuilder private var middleView: some View {
        switch middle {
        case .none:
            // Reserve the progress bar's height so bar-states and text-states are the same height.
            Color.clear.frame(height: 6)
        case let .notes(items):
            if !items.isEmpty {
                ReleaseNotesSection(items: items, expanded: notesExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .progress(fraction):
            UpdateProgressBar(fraction: fraction).padding(.horizontal, Tokens.micro)
        }
    }

    @ViewBuilder private var buttonRow: some View {
        if let primary, let secondary {
            HStack(spacing: Tokens.space) {
                UpdateActionButton(title: secondary.title, systemImage: secondary.icon,
                                   fillWidth: true, action: secondary.run)
                UpdateActionButton(title: primary.title, systemImage: primary.icon,
                                   primary: true, fillWidth: true, action: primary.run)
            }
        } else if let one = primary ?? secondary {
            UpdateActionButton(title: one.title, systemImage: one.icon,
                               primary: primary != nil, width: singleButtonWidth, action: one.run)
        }
    }
}

// MARK: - The single source of truth for each state's copy + layout

/// One authority for every update-state dialog, so the live driver and the dev gallery render the
/// exact same thing — change a header or a verb here and both update, with no chance of drift.
extension UpdateDialog {
    static func permission(onAllow: @escaping () -> Void, onDecline: @escaping () -> Void) -> UpdateDialog {
        UpdateDialog(
            header: "Check for updates automatically?",
            subheader: "RememBar can check for new versions on its own. Updates are signed and installed in place.",
            primary: .init(title: "Check", run: onAllow),
            secondary: .init(title: "Not Now", run: onDecline))
    }

    static func checking(onCancel: @escaping () -> Void) -> UpdateDialog {
        UpdateDialog(
            header: "Checking for updates…",
            subheader: "Contacting the update server",
            middle: .progress(nil),
            secondary: .init(title: "Cancel", run: onCancel))
    }

    static func progress(heading: String, version: String, fraction: Double?,
                         onCancel: (() -> Void)?) -> UpdateDialog {
        UpdateDialog(
            header: heading,
            subheader: "RememBar \(version)",
            middle: .progress(fraction),
            secondary: onCancel.map { .init(title: "Cancel", run: $0) })
    }

    // The available dialog legitimately carries both versions, the notes + their expand-state, and
    // two actions — a factory's job is exactly to hold that shape in one place.
    // swiftlint:disable:next function_parameter_count
    static func available(version: String, currentVersion: String, notes: [String],
                          notesExpanded: Binding<Bool>,
                          onInstall: @escaping () -> Void,
                          onRemindLater: @escaping () -> Void) -> UpdateDialog {
        UpdateDialog(
            header: "A new version is available!",
            subheader: "RememBar \(version) is available — you have \(currentVersion).",
            middle: .notes(notes),
            notesExpanded: notesExpanded,
            primary: .init(title: "Install Update", icon: "arrow.down.circle.fill", run: onInstall),
            secondary: .init(title: "Remind Me Later", run: onRemindLater))
    }

    static func ready(version: String, onRestart: @escaping () -> Void) -> UpdateDialog {
        UpdateDialog(
            header: "Update ready",
            badge: "checkmark.circle.fill",
            subheader: "RememBar \(version) has been downloaded.",
            primary: .init(title: "Restart Now", run: onRestart))
    }

    static func upToDate(version: String, onOK: @escaping () -> Void) -> UpdateDialog {
        UpdateDialog(
            header: "You're up to date!",
            subheader: "RememBar \(version) is the newest version.",
            primary: .init(title: "OK", run: onOK))
    }

    static func error(message: String, onOK: @escaping () -> Void) -> UpdateDialog {
        UpdateDialog(header: "Update error", subheader: message, primary: .init(title: "OK", run: onOK))
    }
}

/// A plain rounded card that mocks the dialog window in the gallery (the real driver uses a system
/// window). No title bar — the header line carries the state.
struct GalleryDialogFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .fixedSize()
            .background(updateWindowBG)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.45), lineWidth: 1))
    }
}
