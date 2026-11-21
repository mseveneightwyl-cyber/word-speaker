import AppKit
import ApplicationServices

enum SelectionRead {
    case selection(Selection)
    case empty
    case unavailable
}

enum AccessibilityReader {
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func parameter(_ element: AXUIElement, _ name: String, _ input: CFTypeRef) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &value) == .success else { return nil }
        return value as? String
    }

    private static func selection(in element: AXUIElement, pid: pid_t) -> SelectionRead? {
        // Never read values from secure input fields.
        if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return .empty }
        var selectedRange = CFRange(location: 0, length: 0)
        var rangeIdentity = ""
        let range = attribute(element, kAXSelectedTextRangeAttribute)
        if let value = range,
           CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetValue(value as! AXValue, .cfRange, &selectedRange) {
            rangeIdentity = "\(selectedRange.location):\(selectedRange.length)"
        }
        let direct = attribute(element, kAXSelectedTextAttribute) as? String
        var text = direct
        if direct?.isEmpty != false {
            if let range, selectedRange.length > 0, selectedRange.length <= 320 {
                text = parameter(element, kAXStringForRangeParameterizedAttribute, range) ?? text
            }
            if text?.isEmpty != false, let marker = attribute(element, "AXSelectedTextMarkerRange") {
                text = parameter(element, "AXStringForTextMarkerRange", marker) ?? text
            }
        }
        guard let text else { return nil }
        guard let selection = Selection.english(text, identity: "\(pid):\(CFHash(element)):\(rangeIdentity)") else {
            return .empty
        }
        return .selection(selection)
    }

    static func read(pid: pid_t) -> SelectionRead {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.12)
        let focused = element(attribute(application, kAXFocusedUIElementAttribute))
        let window = element(attribute(application, kAXFocusedWindowAttribute))
        let deadline = Date().addingTimeInterval(0.45)
        var sawEmpty = false
        var visited: Set<CFHashCode> = []

        func inspect(_ candidate: AXUIElement) -> Selection? {
            guard Date() < deadline, visited.insert(CFHash(candidate)).inserted else { return nil }
            AXUIElementSetMessagingTimeout(candidate, 0.08)
            switch selection(in: candidate, pid: pid) {
            case .selection(let value): return value
            case .empty: sawEmpty = true
            case .unavailable, nil: break
            }
            return nil
        }

        var ancestor = focused
        for _ in 0..<10 {
            guard let current = ancestor, Date() < deadline else { break }
            // A password field terminates the search, including its ancestors.
            if attribute(current, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return .empty }
            if let value = inspect(current) { return .selection(value) }
            ancestor = element(attribute(current, kAXParentAttribute))
        }
        for candidate in [application, window].compactMap({ $0 }) {
            if let value = inspect(candidate) { return .selection(value) }
        }

        // Some browsers expose selection on a descendant of the focused group.
        // Bound the walk so an unresponsive application cannot stall the UI.
        var queue: [(AXUIElement, Int)] = [focused, window].compactMap { $0 }.map { ($0, 0) }
        var expanded: Set<CFHashCode> = []
        var count = 0
        while !queue.isEmpty, count < 48, Date() < deadline {
            let (current, depth) = queue.removeFirst()
            guard expanded.insert(CFHash(current)).inserted else { continue }
            count += 1
            if let value = inspect(current) { return .selection(value) }
            if depth < 6, let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(20).map { ($0, depth + 1) })
            }
        }
        return sawEmpty ? .empty : .unavailable
    }
}
