import AppKit
import SwiftUI
import XCTest
@testable import DesnotchCore

/// Renders the real `PillMarqueeText` and checks that a long title actually moves once the
/// pill is expanded. The first version of the marquee read `isActive`/`plan` through `self`
/// inside `onChange`, saw the previous render's values, and never started: every unit test of
/// the pure `MarqueePlan` passed while the title sat frozen mid-glyph.
@MainActor
final class PillMarqueeRenderTests: XCTestCase {
    /// Lets SwiftUI and the main queue run (the marquee steps are main-queue timers).
    private func pump(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Polls `condition` until it holds or `timeout` passes (waits on the actual state, not a
    /// fixed sleep, so a slow runner only makes the test slower, never flaky).
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await pump(0.1)
        }
        return condition()
    }

    /// What the window server composited: `cacheDisplay` does not capture SwiftUI's layers.
    private func snapshot(_ window: NSWindow) -> Data? {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]
        ) else { return nil }
        let d = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        return d
    }

    private final class Box: ObservableObject {
        @Published var active = false
    }

    private struct Host: View {
        @ObservedObject var box: Box
        var body: some View {
            PillMarqueeText(
                text: "The Extraordinarily Long Title of a Progressive Rock Suite",
                font: .system(size: 12, weight: .semibold),
                color: .white,
                lineHeight: 16,
                isActive: box.active,
                allowsScroll: true,
                fadeAnimation: .easeInOut(duration: 0.12)
            )
            .frame(width: 120, height: 16)
            .background(Color.black)
        }
    }

    func testLongTitleScrollsAfterTheStartDelayOnceActive() async throws {
        // A window server connection is needed for the window to composite at all.
        NSApplication.shared.setActivationPolicy(.accessory)
        let box = Box()
        let host = NSHostingView(rootView: Host(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 16)
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 400, width: 120, height: 16),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // The first SwiftUI window in a cold process (CI runners) can take well over a second
        // to measure the widths, and until it does the line renders as a plain truncated title,
        // a different image from the marquee's resting frame. Take "resting" only once the
        // picture has stopped changing after a generous warm-up, never after a fixed short sleep.
        await pump(1.5)
        var resting = try XCTUnwrap(snapshot(window))
        for _ in 0..<20 {
            await pump(0.5)
            let next = try XCTUnwrap(snapshot(window))
            if next == resting { break }
            resting = next
        }
        XCTAssertEqual(try XCTUnwrap(snapshot(window)), resting, "collapsed: the title rests")

        box.active = true
        let scrolledAway = await waitUntil(timeout: MarqueePlan.startDelay + 8.0) {
            self.snapshot(window).map { $0 != resting } ?? false
        }
        XCTAssertTrue(scrolledAway, "expanded: the title must have scrolled")

        box.active = false
        let returned = await waitUntil(timeout: 8.0) {
            self.snapshot(window).map { $0 == resting } ?? false
        }
        XCTAssertTrue(returned, "collapsing returns it to the start")
    }
}
