import ApplicationServices
import DayreedCore
import Foundation

struct AccessibilityLimits: Sendable {
    var nodes = 120
    var depth = 10
    var textUTF16Units = 12_000
    var titleUTF16Units = 512
    var seconds = 0.8
    var callTimeout: Float = 0.04
}

struct AccessibilityElementText {
    var text: String = ""
    var secure = false
    var unavailable = false
    var truncated = false
}

/// Shared traversal makes the actual count/depth/text bounds testable with synthetic trees.
struct AccessibilityTraversal<Node: Equatable> {
    let limits: AccessibilityLimits
    let text: (Node, Int) -> AccessibilityElementText
    let children: (Node, Int) -> (nodes: [Node], truncated: Bool, unavailable: Bool)
    let outOfTime: () -> Bool

    func read(root: Node) -> (text: String?, quality: CaptureQuality) {
        var queue = [(root, 0)]
        var index = 0
        var visited: [Node] = []
        var fragments: [String] = []
        var remaining = limits.textUTF16Units
        var truncated = false
        var unavailable = false
        while index < queue.count, visited.count < limits.nodes, remaining > 0 {
            if outOfTime() { truncated = true; break }
            let (node, depth) = queue[index]
            index += 1
            if visited.contains(node) { continue }
            visited.append(node)
            let value = text(node, remaining)
            unavailable = unavailable || value.unavailable
            truncated = truncated || value.truncated
            if value.secure { continue }
            let bounded = boundedAccessibilityText(value.text, limit: remaining)
            truncated = truncated || bounded.truncated
            let fragment = bounded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fragment.isEmpty {
                fragments.append(fragment)
                remaining -= fragment.utf16.count + 1
            }
            guard remaining > 0, !outOfTime() else { truncated = true; break }
            // Never ask AX for an unbounded children array, including for a wide root.
            let capacity = max(0, limits.nodes - queue.count)
            let result = children(node, max(1, capacity))
            unavailable = unavailable || result.unavailable
            truncated = truncated || result.truncated
            if depth < limits.depth, capacity > 0 {
                queue.append(contentsOf: result.nodes.prefix(capacity).map { ($0, depth + 1) })
                truncated = truncated || result.nodes.count > capacity
            } else if !result.nodes.isEmpty { truncated = true }
        }
        if index < queue.count { truncated = true }
        let result = boundedAccessibilityText(fragments.joined(separator: "\n"), limit: limits.textUTF16Units).text
        let quality: CaptureQuality = truncated ? .truncated : (unavailable ? .unavailable : (result.isEmpty ? .empty : .available))
        return (result.isEmpty ? nil : result, quality)
    }
}

/// Runs on a utility worker. It only reads AX attributes; secure text controls are skipped.
enum AccessibilityReader {
    static func read(processIdentifier: Int32, windowTitle: Bool, accessibilityText: Bool,
                     limits: AccessibilityLimits = AccessibilityLimits()) -> HistorySample {
        guard AXIsProcessTrusted() else {
            return HistorySample(windowTitleQuality: windowTitle ? .permissionRequired : .disabled,
                                 accessibilityTextQuality: accessibilityText ? .permissionRequired : .disabled)
        }
        let began = ContinuousClock.now
        let timedOut = { began.duration(to: .now) > .seconds(limits.seconds) || Task.isCancelled }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, limits.callTimeout)
        var focused: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        guard windowStatus == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return HistorySample(windowTitleQuality: windowTitle ? .unavailable : .disabled,
                                 accessibilityTextQuality: accessibilityText ? .unavailable : .disabled)
        }
        let window = unsafeDowncast(focused, to: AXUIElement.self)
        var title: String?
        var titleQuality: CaptureQuality = .disabled
        if windowTitle {
            let result = string(window, attribute: kAXTitleAttribute, limit: limits.titleUTF16Units, timeout: limits.callTimeout)
            title = result.text.isEmpty ? nil : result.text
            titleQuality = result.unavailable ? .unavailable : (result.truncated ? .truncated : (title == nil ? .empty : .available))
        }
        var content: String?
        var contentQuality: CaptureQuality = .disabled
        if accessibilityText {
            let traversal = AccessibilityTraversal<AXUIElement>(
                limits: limits,
                text: { element, remaining in
                    if timedOut() { return AccessibilityElementText(truncated: true) }
                    let role = string(element, attribute: kAXRoleAttribute, limit: 100, timeout: limits.callTimeout)
                    let subrole = string(element, attribute: kAXSubroleAttribute, limit: 100, timeout: limits.callTimeout)
                    if role.text == "AXSecureTextField" || subrole.text == "AXSecureTextField" {
                        return AccessibilityElementText(secure: true)
                    }
                    // If role cannot be inspected, do not read a potentially secure control's value.
                    if role.unavailable || subrole.unavailable || role.text.isEmpty { return AccessibilityElementText(secure: true, unavailable: true) }
                    var result = AccessibilityElementText()
                    // Exclude AXTitle here: the independent window-title switch owns title collection.
                    for attribute in [kAXValueAttribute, kAXDescriptionAttribute] {
                        if timedOut() { result.truncated = true; break }
                        let capacity = remaining - result.text.utf16.count
                        if capacity <= 0 { result.truncated = true; break }
                        let value = string(element, attribute: attribute, limit: capacity, timeout: limits.callTimeout)
                        result.unavailable = result.unavailable || value.unavailable
                        result.truncated = result.truncated || value.truncated
                        if !value.text.isEmpty {
                            if !result.text.isEmpty { result.text += "\n" }
                            result.text += value.text
                        }
                    }
                    return result
                },
                children: { element, maximum in
                    if timedOut() { return ([], true, false) }
                    AXUIElementSetMessagingTimeout(element, limits.callTimeout)
                    var count = 0
                    let status = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                    if status == .attributeUnsupported || status == .noValue { return ([], false, false) }
                    guard status == .success else { return ([], false, true) }
                    if count == 0 { return ([], false, false) }
                    if timedOut() { return ([], true, false) }
                    var array: CFArray?
                    let read = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString,
                                                             0, min(count, maximum), &array)
                    guard read == .success, let array else { return ([], false, true) }
                    let nodes = (array as [AnyObject]).compactMap { value -> AXUIElement? in
                        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                        return unsafeDowncast(value, to: AXUIElement.self)
                    }
                    return (nodes, count > maximum, false)
                },
                outOfTime: timedOut
            )
            (content, contentQuality) = traversal.read(root: window)
        }
        return HistorySample(windowTitle: title, accessibilityText: content,
                             windowTitleQuality: titleQuality, accessibilityTextQuality: contentQuality)
    }

    private static func string(_ element: AXUIElement, attribute: String, limit: Int, timeout: Float) -> AccessibilityElementText {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return AccessibilityElementText() }
        guard status == .success else { return AccessibilityElementText(unavailable: true) }
        guard let value, CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else {
            return AccessibilityElementText()
        }
        let bounded = boundedAccessibilityText(text, limit: limit)
        return AccessibilityElementText(text: bounded.text, truncated: bounded.truncated)
    }
}

/// Prefixing by grapheme count permits one arbitrarily large combining sequence. Bound code
/// units instead, without scanning the entire AX string to decide whether it was truncated.
func boundedAccessibilityText(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
    var iterator = text.utf16.makeIterator()
    var units: [UInt16] = []
    for _ in 0..<max(0, limit) {
        guard let unit = iterator.next() else { break }
        units.append(unit)
    }
    return (String(decoding: units, as: UTF16.self), iterator.next() != nil)
}
