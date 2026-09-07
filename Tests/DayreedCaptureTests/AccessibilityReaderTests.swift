import DayreedCore
import Testing
@testable import DayreedCapture

@Test func AXTraversalBoundsWideCyclicTreesAndText() {
    var limits = AccessibilityLimits()
    limits.nodes = 4
    limits.textUTF16Units = 12
    var visited: [Int] = []
    var maxRequestedChildren = 0
    let traversal = AccessibilityTraversal<Int>(limits: limits, text: { node, maximum in
        visited.append(node)
        return AccessibilityElementText(text: String(repeating: "x", count: min(5, maximum)))
    }, children: { node, maximum in
        maxRequestedChildren = max(maxRequestedChildren, maximum)
        return (Array([node, 1, 2, 3, 4, 5].prefix(maximum)), true, false)
    }, outOfTime: { false })
    let result = traversal.read(root: 0)
    #expect(visited.count <= 4)
    #expect(Set(visited).count == visited.count)
    #expect(maxRequestedChildren <= 3)
    #expect((result.text?.count ?? 0) <= 12)
    #expect(result.quality == .truncated)
}

@Test func AXTraversalSkipsSecureSubtreesAndDistinguishesEmptyUnavailableAndTimeout() {
    let limits = AccessibilityLimits()
    var childrenRead = false
    let secure = AccessibilityTraversal<Int>(limits: limits, text: { _, _ in
        AccessibilityElementText(text: "SYNTHETIC_PASSWORD", secure: true)
    }, children: { _, _ in childrenRead = true; return ([1], false, false) }, outOfTime: { false }).read(root: 0)
    #expect(secure.text == nil)
    #expect(secure.quality == .empty)
    #expect(!childrenRead)
    for unavailable in [false, true] {
        let result = AccessibilityTraversal<Int>(limits: limits, text: { _, _ in
            AccessibilityElementText(unavailable: unavailable)
        }, children: { _, _ in ([], false, false) }, outOfTime: { false }).read(root: 0)
        #expect(result.quality == (unavailable ? .unavailable : .empty))
    }
    let timeout = AccessibilityTraversal<Int>(limits: limits, text: { _, _ in
        Issue.record("timed-out traversal must not read a node")
        return AccessibilityElementText()
    }, children: { _, _ in ([], false, false) }, outOfTime: { true }).read(root: 0)
    #expect(timeout.quality == .truncated)
}

@Test func AXTraversalStopsAtDepthLimit() {
    var limits = AccessibilityLimits()
    limits.depth = 2
    var visited: [Int] = []
    let result = AccessibilityTraversal<Int>(limits: limits, text: { node, _ in
        visited.append(node)
        return AccessibilityElementText(text: "sample")
    }, children: { node, _ in ([node + 1], false, false) }, outOfTime: { false }).read(root: 0)
    #expect(visited == [0, 1, 2])
    #expect(result.quality == .truncated)
}

@Test func AXTextLimitsAlsoBoundLargeCombiningCharactersAndSurrogatePairs() {
    let pathological = "a" + String(repeating: "\u{0301}", count: 20_000)
    #expect(pathological.count == 1)
    let bounded = boundedAccessibilityText(pathological, limit: 100)
    #expect(bounded.text.utf16.count == 100)
    #expect(bounded.truncated)
    let emoji = boundedAccessibilityText(String(repeating: "🙂", count: 20), limit: 3)
    #expect(emoji.text.utf16.count <= 3)
    #expect(emoji.truncated)
    #expect(!boundedAccessibilityText("sample", limit: 6).truncated)
}
