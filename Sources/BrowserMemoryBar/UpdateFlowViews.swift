#if DEBUG
import SwiftUI

// Faithful recreations of Sparkle's update-flow dialogs, matched to real screenshots, so the flow
// can be seen and restyled in the gallery WITHOUT triggering a real update. The live app still uses
// Sparkle's standard UI — making these the real update UI means implementing a custom SPUUserDriver
// (a scoped follow-up). Kept #if DEBUG until then.
//
// The button treatment is the PROPOSED grouping: both actions together bottom-right (secondary +
// primary-blue, a gap between), not spread to the window's edges the way Sparkle's default does.

private let updateWindowBG = Color(red: 0.157, green: 0.157, blue: 0.169)

/// A faux titled window (traffic lights + optional centered title) so a state reads as its dialog.
private struct UpdateWindow<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.muted)
                }
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 0.99, green: 0.37, blue: 0.35)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.98, green: 0.74, blue: 0.28)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.24, green: 0.79, blue: 0.33)).frame(width: 12, height: 12)
                    Spacer()
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 13)

            content
        }
        .background(updateWindowBG)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

/// The confirming/primary button (blue) — Sparkle's Install button + the app's accent.
private struct UpdatePrimaryButton: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Tokens.space + Tokens.micro + 2)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tokens.accent))
    }
}

private struct UpdateSecondaryButton: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, Tokens.space + Tokens.micro + 2)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tokens.row))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Tokens.line, lineWidth: 1))
    }
}

private struct UpdateProgressBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.row)
                Capsule().fill(Tokens.accent).frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

/// 1) Update available — icon + copy, PROPOSED grouped buttons bottom-right.
struct UpdateAvailableView: View {
    var body: some View {
        UpdateWindow(title: nil) {
            VStack(alignment: .leading, spacing: Tokens.space + Tokens.micro + 2) {
                HStack(alignment: .top, spacing: Tokens.space + Tokens.micro) {
                    AppIconView().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: Tokens.micro + 2) {
                        Text("A new version of RememBar is available!")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Tokens.text)
                        Text("RememBar 0.2.0 is now available—you have 0.1.0. Would you like to download it now?")
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: Tokens.space + 2) {
                    Spacer(minLength: 0)
                    UpdateSecondaryButton(title: "Skip This Version")
                    UpdatePrimaryButton(title: "Install Update")
                }
            }
            .padding(Tokens.space + Tokens.micro + 2)
        }
        .frame(width: 470)
    }
}

/// 2) Checking for updates — indeterminate-style progress + Cancel.
struct UpdateCheckingView: View {
    var body: some View {
        UpdateWindow(title: "Software Update") {
            HStack(alignment: .top, spacing: Tokens.space + Tokens.micro) {
                AppIconView().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: Tokens.space + 2) {
                    Text("Checking for updates…")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Tokens.text)
                    UpdateProgressBar(fraction: 0.4)
                    HStack {
                        Spacer()
                        UpdateSecondaryButton(title: "Cancel")
                    }
                }
            }
            .padding(Tokens.space + Tokens.micro + 2)
        }
        .frame(width: 430)
    }
}

/// 3) Ready to install — full progress + primary "Install and Relaunch".
struct UpdateReadyView: View {
    var body: some View {
        UpdateWindow(title: "Updating RememBar") {
            HStack(alignment: .top, spacing: Tokens.space + Tokens.micro) {
                AppIconView().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: Tokens.space + 2) {
                    Text("Ready to Install")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Tokens.text)
                    UpdateProgressBar(fraction: 1.0)
                    HStack {
                        Spacer()
                        UpdatePrimaryButton(title: "Install and Relaunch")
                    }
                }
            }
            .padding(Tokens.space + Tokens.micro + 2)
        }
        .frame(width: 430)
    }
}

/// 4) Up to date — centered, plain panel (no title bar), full-width OK.
struct UpToDateView: View {
    var body: some View {
        VStack(spacing: Tokens.space + Tokens.micro) {
            AppIconView().frame(width: 76, height: 76)
            Text("You're up to date!")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Tokens.text)
            Text("RememBar 0.2.0 is currently the newest version available.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("OK")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tokens.accent))
                .padding(.top, Tokens.micro)
        }
        .padding(Tokens.space + Tokens.micro + 4)
        .frame(width: 300)
        .background(updateWindowBG)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}
#endif
