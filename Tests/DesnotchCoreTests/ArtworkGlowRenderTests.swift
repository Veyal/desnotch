import AppKit
import SwiftUI
import XCTest
@testable import DesnotchCore

/// Renders the real `ArtworkGlow` and changes its accent. The first version read `accent`
/// through `self` inside `onChange`, which returns the previous render's value there, so each
/// track change crossfaded to the previous track's colour and the glow stayed one track behind.
@MainActor
final class ArtworkGlowRenderTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// What the window server composited: `cacheDisplay` does not capture SwiftUI's layers.
    private func snapshot(_ window: NSWindow) -> Data? {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]
        ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private final class Box: ObservableObject {
        @Published var accent: NSColor?
        init(_ accent: NSColor?) { self.accent = accent }
    }

    private struct Host: View {
        @ObservedObject var box: Box
        var body: some View {
            ArtworkGlow(
                accent: box.accent,
                isPlaying: true,
                motion: NotchAnimation.resolve(style: .minimal, reduceMotion: false)
            )
            .frame(width: 160, height: 40)
            .background(Color.black)
        }
    }

    func testGlowFollowsTheCurrentAccentNotThePreviousOne() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let red = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let blue = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.95, alpha: 1)
        let green = NSColor(srgbRed: 0.1, green: 0.9, blue: 0.2, alpha: 1)
        let box = Box(red)
        let host = NSHostingView(rootView: Host(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 40)
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 160, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        await pump(0.4)
        let first = try XCTUnwrap(snapshot(window))

        box.accent = blue
        await pump(0.6)
        let second = try XCTUnwrap(snapshot(window))
        XCTAssertNotEqual(second, first, "track 2 shows its own colour, not track 1's again")

        box.accent = green
        await pump(0.6)
        let third = try XCTUnwrap(snapshot(window))
        XCTAssertNotEqual(third, second, "track 3 shows its own colour, not track 2's")
        XCTAssertNotEqual(third, first)

        box.accent = blue
        await pump(0.6)
        XCTAssertEqual(try XCTUnwrap(snapshot(window)), second, "the same accent renders the same glow")
    }
}
