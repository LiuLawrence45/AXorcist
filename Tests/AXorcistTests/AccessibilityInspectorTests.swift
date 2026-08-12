import CoreGraphics
import Foundation
import Testing
@testable import axorc

@Suite("Accessibility inspector", .tags(.safe))
struct AccessibilityInspectorTests {
    @Test
    func `Escape ends the inspector session`() {
        #expect(AccessibilityInspectorKeyboard.shouldEndSession(
            eventType: .keyDown,
            keyCode: AccessibilityInspectorKeyboard.escapeKeyCode))
        #expect(!AccessibilityInspectorKeyboard.shouldEndSession(
            eventType: .keyUp,
            keyCode: AccessibilityInspectorKeyboard.escapeKeyCode))
        #expect(!AccessibilityInspectorKeyboard.shouldEndSession(eventType: .keyDown, keyCode: 36))
    }

    @Test
    func `Coordinate conversion bridges AppKit and AX screen origins`() {
        let axPoint = AccessibilityInspectorCoordinateSpace.accessibilityPoint(
            fromAppKit: CGPoint(x: 120, y: 700),
            primaryScreenMaxY: 1000)
        #expect(axPoint == CGPoint(x: 120, y: 300))

        let appKitRect = AccessibilityInspectorCoordinateSpace.appKitRect(
            fromAccessibility: CGRect(x: 120, y: 300, width: 240, height: 80),
            primaryScreenMaxY: 1000)
        #expect(appKitRect == CGRect(x: 120, y: 620, width: 240, height: 80))
    }

    @Test
    func `Window resolver picks the frontmost underlying application`() {
        let windows = [
            AccessibilityInspectorWindow(ownerPID: 50, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
            AccessibilityInspectorWindow(ownerPID: 20, bounds: CGRect(x: 100, y: 100, width: 200, height: 200)),
            AccessibilityInspectorWindow(ownerPID: 30, bounds: CGRect(x: 100, y: 100, width: 200, height: 200)),
        ]

        #expect(AccessibilityInspectorWindowResolver.applicationPIDs(
            at: CGPoint(x: 150, y: 150),
            excluding: 50,
            windows: windows) == [20, 30])
        #expect(AccessibilityInspectorWindowResolver.applicationPIDs(
            at: CGPoint(x: 600, y: 600),
            excluding: 50,
            windows: windows).isEmpty)
    }

    @Test
    func `Depth resolver chooses the smallest containing child`() {
        let frames: [CGRect?] = [
            CGRect(x: 0, y: 0, width: 500, height: 500),
            CGRect(x: 100, y: 100, width: 200, height: 200),
            CGRect(x: 140, y: 140, width: 40, height: 40),
            nil,
        ]

        #expect(AccessibilityInspectorDepthResolver.smallestContainingFrameIndex(
            at: CGPoint(x: 150, y: 150),
            frames: frames) == 2)
        #expect(AccessibilityInspectorDepthResolver.smallestContainingFrameIndex(
            at: CGPoint(x: 600, y: 600),
            frames: frames) == nil)
    }

    @Test
    func `Markdown includes stable location and reusable query`() throws {
        let snapshot = AccessibilityInspectorSnapshot(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            pid: 42,
            role: "AXButton",
            subrole: nil,
            title: "Back",
            identifier: "back-button",
            description: "Go back",
            enabled: true,
            actions: ["AXPress"],
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            path: "Role: AXWindow -> Role: AXButton, Title: 'Back'")

        let markdown = AccessibilityInspectorMarkdown.render(snapshot)

        #expect(markdown.contains("- App: `Safari`"))
        #expect(markdown.contains("- Frame: `x=10, y=20, width=30, height=40`"))
        #expect(markdown.contains("Role: AXWindow -> Role: AXButton"))
        #expect(markdown.contains("\"application\" : \"com.apple.Safari\""))
        #expect(markdown.contains("\"attribute\" : \"AXIdentifier\""))
        #expect(markdown.contains("\"value\" : \"back-button\""))
    }

    @Test
    func `Markdown uses title when identifier is unavailable`() {
        let snapshot = AccessibilityInspectorSnapshot(
            applicationName: "Notes",
            bundleIdentifier: nil,
            pid: 7,
            role: "AXButton",
            subrole: "AXCloseButton",
            title: "Add `note`",
            identifier: nil,
            description: nil,
            enabled: true,
            actions: [],
            frame: CGRect(x: 0, y: 0, width: 10.5, height: 20),
            path: "AXButton with ``` from untrusted title")

        let markdown = AccessibilityInspectorMarkdown.render(snapshot)

        #expect(markdown.contains("\"attribute\" : \"AXTitle\""))
        #expect(markdown.contains("\"attribute\" : \"AXSubrole\""))
        #expect(markdown.contains("\"value\" : \"AXCloseButton\""))
        #expect(markdown.contains("\"value\" : \"Add `note`\""))
        #expect(markdown.contains("- Title: `` Add `note` ``"))
        #expect(markdown.contains("width=10.5"))
        #expect(markdown.contains("````text\nAXButton with ``` from untrusted title\n````"))
    }
}
