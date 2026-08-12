import AppKit
import ApplicationServices
import AXorcist
import Foundation

struct AccessibilityInspectorSnapshot {
    let applicationName: String?
    let bundleIdentifier: String?
    let pid: pid_t?
    let role: String?
    let subrole: String?
    let title: String?
    let identifier: String?
    let description: String?
    let enabled: Bool?
    let actions: [String]
    let frame: CGRect
    let path: String
}

enum AccessibilityInspectorCoordinateSpace {
    static func accessibilityPoint(fromAppKit point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    static func appKitRect(fromAccessibility rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenMaxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height)
    }
}

enum AccessibilityInspectorMarkdown {
    static func render(_ snapshot: AccessibilityInspectorSnapshot) -> String {
        var lines = ["## Accessibility element", ""]
        Self.append("App", value: snapshot.applicationName, to: &lines)
        Self.append("Bundle identifier", value: snapshot.bundleIdentifier, to: &lines)
        Self.append("PID", value: snapshot.pid.map(String.init), to: &lines)
        Self.append("Role", value: snapshot.role, to: &lines)
        Self.append("Subrole", value: snapshot.subrole, to: &lines)
        Self.append("Title", value: snapshot.title, to: &lines)
        Self.append("Identifier", value: snapshot.identifier, to: &lines)
        Self.append("Description", value: snapshot.description, to: &lines)
        Self.append("Enabled", value: snapshot.enabled.map(String.init), to: &lines)
        if !snapshot.actions.isEmpty {
            Self.append("Actions", value: snapshot.actions.joined(separator: ", "), to: &lines)
        }
        Self.append("Frame", value: Self.frameDescription(snapshot.frame), to: &lines)

        lines.append(contentsOf: [
            "",
            "### Accessibility path",
            "",
            Self.fencedBlock(language: "text", content: snapshot.path),
            "",
            "### AXorcist query",
            "",
            Self.fencedBlock(language: "json", content: Self.queryJSON(for: snapshot)),
        ])
        return lines.joined(separator: "\n")
    }

    private static func append(_ label: String, value: String?, to lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        lines.append("- \(label): \(Self.codeSpan(value))")
    }

    private static func codeSpan(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let fence = String(repeating: "`", count: max(1, Self.longestBacktickRun(in: sanitized) + 1))
        let needsPadding = sanitized.first == "`" || sanitized.last == "`" ||
            sanitized.first?.isWhitespace == true || sanitized.last?.isWhitespace == true
        let padding = needsPadding ? " " : ""
        return "\(fence)\(padding)\(sanitized)\(padding)\(fence)"
    }

    private static func fencedBlock(language: String, content: String) -> String {
        let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: content) + 1))
        return "\(fence)\(language)\n\(content)\n\(fence)"
    }

    private static func longestBacktickRun(in value: String) -> Int {
        var currentRun = 0
        var longestRun = 0
        for character in value {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return longestRun
    }

    private static func frameDescription(_ frame: CGRect) -> String {
        "x=\(Self.number(frame.minX)), y=\(Self.number(frame.minY)), " +
            "width=\(Self.number(frame.width)), height=\(Self.number(frame.height))"
    }

    private static func number(_ value: CGFloat) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    private static func queryJSON(for snapshot: AccessibilityInspectorSnapshot) -> String {
        var criteria: [[String: String]] = []
        if let role = snapshot.role {
            criteria.append(["attribute": "AXRole", "value": role])
        }
        if let subrole = snapshot.subrole, !subrole.isEmpty {
            criteria.append(["attribute": "AXSubrole", "value": subrole])
        }
        if let identifier = snapshot.identifier, !identifier.isEmpty {
            criteria.append(["attribute": "AXIdentifier", "value": identifier])
        } else if let title = snapshot.title, !title.isEmpty {
            criteria.append(["attribute": "AXTitle", "value": title])
        } else if let description = snapshot.description, !description.isEmpty {
            criteria.append(["attribute": "AXDescription", "value": description])
        }

        let application = snapshot.bundleIdentifier ??
            snapshot.applicationName ??
            snapshot.pid.map(String.init) ??
            "focused"
        let query: [String: Any] = [
            "application": application,
            "attributes": [
                "AXRole", "AXSubrole", "AXTitle", "AXIdentifier", "AXDescription",
                "AXEnabled", "AXPosition", "AXSize",
            ],
            "command": "query",
            "command_id": "inspect-selection",
            "locator": ["criteria": criteria],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: query,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

@MainActor
final class AccessibilityInspectorController {
    init(stayOpen: Bool) {
        self.stayOpen = stayOpen
    }

    func run() -> Int32 {
        guard let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY else {
            fputs("axorc inspect: No display is available.\n", stderr)
            return 1
        }

        self.primaryScreenMaxY = primaryScreenMaxY
        self.configureApplication()
        self.configureOverlay()
        self.startTracking()
        fputs("Move the pointer over an element, then click the green highlight to copy Markdown.\n", stderr)
        fputs("Press Control-C in the terminal to cancel.\n", stderr)
        fflush(stderr)
        NSApplication.shared.run()
        return self.exitCode
    }

    private let stayOpen: Bool
    private let overlay = AccessibilityInspectorOverlayPanel()
    private var timer: Timer?
    private var currentElement: Element?
    private var currentFrame: CGRect?
    private var primaryScreenMaxY: CGFloat = 0
    private var exitCode: Int32 = 0

    private func configureApplication() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }

    private func configureOverlay() {
        self.overlay.onCapture = { [weak self] in
            self?.captureCurrentElement()
        }
    }

    // Polling keeps hover inspection responsive without requiring Input Monitoring permission.
    private func startTracking() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHoveredElement()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.updateHoveredElement()
    }

    private func updateHoveredElement() {
        let appKitPoint = NSEvent.mouseLocation
        let accessibilityPoint = AccessibilityInspectorCoordinateSpace.accessibilityPoint(
            fromAppKit: appKitPoint,
            primaryScreenMaxY: self.primaryScreenMaxY)

        guard let element = self.elementUnderPointer(at: accessibilityPoint) else {
            self.clearSelection()
            return
        }
        guard let frame = element.frame(),
              frame.width > 0,
              frame.height > 0
        else {
            self.clearSelection()
            return
        }

        self.currentElement = element
        self.currentFrame = frame
        let overlayFrame = AccessibilityInspectorCoordinateSpace.appKitRect(
            fromAccessibility: frame,
            primaryScreenMaxY: self.primaryScreenMaxY)
        self.overlay.show(frame: overlayFrame)
    }

    private func clearSelection() {
        self.currentElement = nil
        self.currentFrame = nil
        self.overlay.orderOut(nil)
    }

    private func elementUnderPointer(at point: CGPoint) -> Element? {
        guard let element = Element.elementAtPoint(point) else { return nil }
        if self.owningPID(for: element) != ProcessInfo.processInfo.processIdentifier {
            return element
        }

        // Briefly remove the accessibility-hidden overlay as a fallback for apps that still expose its window.
        self.overlay.orderOut(nil)
        return Element.elementAtPoint(point)
    }

    private func snapshot(for element: Element, frame: CGRect) -> AccessibilityInspectorSnapshot {
        let pid = self.owningPID(for: element)
        let application = pid.flatMap(NSRunningApplication.init(processIdentifier:))
        return AccessibilityInspectorSnapshot(
            applicationName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            pid: pid,
            role: element.role(),
            subrole: element.subrole(),
            title: element.title(),
            identifier: element.identifier(),
            description: element.descriptionText(),
            enabled: element.isEnabled(),
            actions: element.supportedActions() ?? [],
            frame: frame,
            path: element.generatePathString())
    }

    // Child AX elements often omit AXPID, so ask the native API for their owning process.
    private func owningPID(for element: Element) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element.underlyingElement, &pid) == .success else { return nil }
        return pid
    }

    private func captureCurrentElement() {
        guard let element = self.currentElement, let frame = self.currentFrame else { return }
        let snapshot = self.snapshot(for: element, frame: frame)
        let markdown = AccessibilityInspectorMarkdown.render(snapshot)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(markdown, forType: .string) else {
            fputs("axorc inspect: Could not write the selection to the clipboard.\n", stderr)
            self.exitCode = 1
            self.stop()
            return
        }

        Swift.print(markdown)
        fflush(stdout)
        fputs("Copied accessibility Markdown to the clipboard.\n", stderr)
        fflush(stderr)
        if !self.stayOpen {
            self.stop()
        }
    }

    private func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.overlay.orderOut(nil)
        NSApplication.shared.stop(nil)
    }
}

@MainActor
private final class AccessibilityInspectorOverlayPanel: NSPanel {
    var onCapture: (() -> Void)? {
        didSet {
            self.overlayView.onCapture = self.onCapture
        }
    }

    init() {
        self.overlayView = AccessibilityInspectorOverlayView(frame: .zero)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.contentView = self.overlayView
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false
        self.isOpaque = false
        self.isReleasedWhenClosed = false
        self.level = .screenSaver
        self.setAccessibilityElement(false)
        self.overlayView.setAccessibilityElement(false)
    }

    private let overlayView: AccessibilityInspectorOverlayView

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(frame: CGRect) {
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite else {
            self.orderOut(nil)
            return
        }
        self.setFrame(frame, display: true)
        self.orderFrontRegardless()
    }
}

@MainActor
private final class AccessibilityInspectorOverlayView: NSView {
    var onCapture: (() -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        self.onCapture?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemGreen.setStroke()
        let lineWidth: CGFloat = 3
        let outline = NSBezierPath(
            roundedRect: self.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: 5,
            yRadius: 5)
        outline.lineWidth = lineWidth
        outline.stroke()
    }
}
