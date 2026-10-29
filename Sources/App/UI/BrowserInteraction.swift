import AppKit
import SwiftUI

/// Transparent layer over a monitor: when the monitor shows a Web Browser input, mouse clicks, drags,
/// moves and scrolling are passed to the page (like clicking a browser input in vMix's Preview), and the
/// first click hands the keyboard to the page until Esc / clicking elsewhere.
struct BrowserInteractionLayer: NSViewRepresentable {
    let browser: BrowserInput?
    /// Size of the frame drawn by the monitor (to undo its letterboxing).
    let sourceSize: () -> CGSize?

    func makeNSView(context: Context) -> BrowserEventView {
        let v = BrowserEventView()
        v.browser = browser
        v.sourceSize = sourceSize
        return v
    }

    func updateNSView(_ v: BrowserEventView, context: Context) {
        v.browser = browser
        v.sourceSize = sourceSize
        v.window?.invalidateCursorRects(for: v)
    }
}

final class BrowserEventView: NSView, NSTextInputClient {
    weak var browser: BrowserInput?
    var sourceSize: () -> CGSize? = { nil }
    private var tracking: NSTrackingArea?

    private var active: Bool { browser?.mouseEnabled == true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        active ? super.hitTest(point) : nil      // otherwise let clicks fall through
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) {
        if active { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    /// View point → normalised page point (nil outside the letterboxed picture).
    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let src = sourceSize() ?? CGSize(width: 16, height: 9)
        let scale = min(b.width / max(1, src.width), b.height / max(1, src.height))
        let w = src.width * scale, h = src.height * scale
        let rect = CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
        guard rect.contains(p) else { return nil }
        let y = isFlipped ? (p.y - rect.minY) / h : (rect.maxY - p.y) / h
        return CGPoint(x: (p.x - rect.minX) / w, y: y)
    }

    private func send(_ type: NSEvent.EventType, _ event: NSEvent) {
        guard active, let b = browser, let pt = pagePoint(event) else { return }
        let clicks = (type == .mouseMoved || type == .leftMouseDragged) ? 0 : event.clickCount
        b.forwardMouse(type, at: pt, clickCount: clicks, modifiers: event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        send(.leftMouseDown, event)
        if browser?.usesEngine == true, browser?.keyboardEnabled == true { window?.makeFirstResponder(self) }
    }
    override func mouseUp(with event: NSEvent) { send(.leftMouseUp, event) }
    override func mouseDragged(with event: NSEvent) { send(.leftMouseDragged, event) }
    override func rightMouseDown(with event: NSEvent) { send(.rightMouseDown, event) }
    override func rightMouseUp(with event: NSEvent) { send(.rightMouseUp, event) }
    override func mouseMoved(with event: NSEvent) { send(.mouseMoved, event) }

    override func scrollWheel(with event: NSEvent) {
        guard active, let b = browser, let pt = pagePoint(event) else { return super.scrollWheel(with: event) }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        b.forwardScroll(dx: event.scrollingDeltaX * k, dy: event.scrollingDeltaY * k, at: pt)
    }

    // MARK: Keyboard → page (embedded engine). Text goes through the input method so Korean works.

    private var marked = ""
    private var markedSel = NSRange(location: 0, length: 0)
    private var handlingKey = false
    private var sentTextForKey = false

    override var acceptsFirstResponder: Bool { browser?.usesEngine == true }

    private var keyMonitor: Any?

    override func becomeFirstResponder() -> Bool {
        browser?.engineFocus(true)
        // Switcher shortcuts (Space = Cut, 1-9 = Preview …) must not fire while typing into the page.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard let self = self, self.window?.firstResponder === self, ev.window === self.window,
                  !ev.modifierFlags.contains(.command) else { return ev }
            if ev.type == .keyDown { self.keyDown(with: ev) } else { self.keyUp(with: ev) }
            return nil
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if !marked.isEmpty { browser?.engineIMECancel(); marked = "" }
        browser?.engineFocus(false)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let b = browser, b.usesEngine else { return super.keyDown(with: event) }
        if event.keyCode == 53 && marked.isEmpty {          // Esc: hand the keyboard back to the switcher
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": b.engineEdit(0); return
            case "x": b.engineEdit(1); return
            case "v": b.engineEdit(2); return
            case "a": b.engineEdit(3); return
            case "z": b.engineEdit(mods.contains(.shift) ? 5 : 4); return
            default: return super.keyDown(with: event)       // let menu shortcuts work
            }
        }
        let win = BrowserEventView.windowsKeyCode(event)
        let ch = event.characters?.utf16.first ?? 0
        let unmod = event.charactersIgnoringModifiers?.utf16.first ?? 0
        b.engineKey(type: 0, macCode: Int(event.keyCode), windowsCode: win, char: ch, unmod: unmod,
                    mods: event.modifierFlags.rawValue)
        handlingKey = true
        sentTextForKey = false
        inputContext?.handleEvent(event)                     // → insertText / setMarkedText / doCommand
        handlingKey = false
        // control keys (arrows, backspace, enter …) produce no text but still need their char event
        if !sentTextForKey && marked.isEmpty, BrowserEventView.isControlKey(event.keyCode), ch != 0 {
            b.engineKey(type: 2, macCode: Int(event.keyCode), windowsCode: win, char: ch, unmod: unmod,
                        mods: event.modifierFlags.rawValue)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let b = browser, b.usesEngine else { return super.keyUp(with: event) }
        b.engineKey(type: 1, macCode: Int(event.keyCode), windowsCode: BrowserEventView.windowsKeyCode(event),
                    char: event.characters?.utf16.first ?? 0, unmod: event.charactersIgnoringModifiers?.utf16.first ?? 0,
                    mods: event.modifierFlags.rawValue)
    }

    static func isControlKey(_ code: UInt16) -> Bool {
        [36, 76, 48, 51, 117, 123, 124, 125, 126, 115, 119, 116, 121].contains(code)
    }

    /// Windows virtual-key codes Chromium expects for editing/navigation keys.
    static func windowsKeyCode(_ e: NSEvent) -> Int {
        switch e.keyCode {
        case 51: return 8      // backspace
        case 48: return 9      // tab
        case 36, 76: return 13 // return / enter
        case 53: return 27     // esc
        case 49: return 32     // space
        case 116: return 33    // page up
        case 121: return 34    // page down
        case 119: return 35    // end
        case 115: return 36    // home
        case 123: return 37
        case 126: return 38
        case 124: return 39
        case 125: return 40
        case 117: return 46    // forward delete
        default:
            if let c = e.charactersIgnoringModifiers?.uppercased().unicodeScalars.first, c.isASCII {
                let v = Int(c.value)
                if (48...57).contains(v) || (65...90).contains(v) { return v }
            }
            return 0
        }
    }

    // NSTextInputClient
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard let b = browser else { return }
        sentTextForKey = true
        if !marked.isEmpty || text.unicodeScalars.count > 1 || !handlingKey {
            b.engineIMECommit(text)                           // committed IME text (e.g. 한글)
        } else if let u = text.utf16.first {
            b.engineKey(type: 2, macCode: 0, windowsCode: 0, char: u, unmod: u, mods: 0)
        }
        marked = ""
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedSel = selectedRange
        sentTextForKey = true
        if marked.isEmpty { browser?.engineIMECancel() } else { browser?.engineIMEComposition(marked, selection: selectedRange) }
    }

    func unmarkText() {
        if !marked.isEmpty { browser?.engineIMECommit(marked) }
        marked = ""
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) {}   // editing keys already went to the page as raw keys
}
