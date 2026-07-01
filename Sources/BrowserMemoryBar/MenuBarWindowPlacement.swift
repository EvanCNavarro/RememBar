import CoreGraphics

enum MenuBarWindowPlacement {
    static func isPanelCandidate(frame: CGRect, isVisible: Bool) -> Bool {
        isVisible &&
            frame.width >= 300 &&
            frame.width <= 640 &&
            frame.height >= 40 &&
            frame.height <= 900
    }

    static func adjustedOrigin(
        for windowFrame: CGRect,
        visibleScreenFrames: [CGRect],
        margin: CGFloat = 8
    ) -> CGPoint? {
        guard !visibleScreenFrames.isEmpty else { return nil }
        guard !visibleScreenFrames.contains(where: { $0.contains(windowFrame) }) else { return nil }

        let screen = nearestScreen(to: windowFrame, in: visibleScreenFrames)
        let originX = clamped(
            windowFrame.minX,
            min: screen.minX + margin,
            max: screen.maxX - windowFrame.width - margin
        )
        let originY = clamped(
            windowFrame.minY,
            min: screen.minY + margin,
            max: screen.maxY - windowFrame.height - margin
        )
        return CGPoint(x: originX, y: originY)
    }

    private static func nearestScreen(to windowFrame: CGRect, in screens: [CGRect]) -> CGRect {
        screens.min { lhs, rhs in
            squaredDistance(from: windowFrame.center, to: lhs.center) <
                squaredDistance(from: windowFrame.center, to: rhs.center)
        } ?? screens[0]
    }

    private static func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard min <= max else { return min }
        return Swift.max(min, Swift.min(max, value))
    }

    private static func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

#if canImport(AppKit)
import AppKit

@MainActor
enum MenuBarWindowPositioner {
    static func scheduleVisibilityCheck(diagnostics: RememBarDiagnostics = .shared) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            keepPanelsVisible(diagnostics: diagnostics)
        }
    }

    static func keepPanelsVisible(diagnostics: RememBarDiagnostics = .shared) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        for window in NSApp.windows where isRememBarPanelCandidate(window) {
            let frame = window.frame
            guard let origin = MenuBarWindowPlacement.adjustedOrigin(
                for: frame, visibleScreenFrames: visibleFrames
            ) else {
                continue
            }
            window.setFrameOrigin(origin)
            diagnostics.record(
                RememBarDiagnosticEvent.uiPanelRepositioned,
                fields: [
                    "from": "\(Int(frame.minX)),\(Int(frame.minY))",
                    "to": "\(Int(origin.x)),\(Int(origin.y))",
                    "size": "\(Int(frame.width))x\(Int(frame.height))"
                ]
            )
        }
    }

    private static func isRememBarPanelCandidate(_ window: NSWindow) -> Bool {
        MenuBarWindowPlacement.isPanelCandidate(frame: window.frame, isVisible: window.isVisible)
    }
}
#endif
