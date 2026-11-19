// Read the real app / mail composer for the native macOS handoff E2E test.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func read(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
    var node: [String: Any] = [:]
    for key in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute] {
        if let value = attribute(element, key) { node[key] = String(describing: value) }
    }
    for key in [kAXPositionAttribute, kAXSizeAttribute] {
        if let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = value as! AXValue
            if key == kAXPositionAttribute {
                var point = CGPoint.zero
                if AXValueGetValue(ax, .cgPoint, &point) { node[key] = [point.x, point.y] }
            } else {
                var size = CGSize.zero
                if AXValueGetValue(ax, .cgSize, &size) { node[key] = [size.width, size.height] }
            }
        }
    }
    if depth < 25, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        node["children"] = children.map { read($0, depth: depth + 1) }
    }
    return node
}
let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:info@instacast.ch")!)
let bundle = CommandLine.arguments[1] == "default-mail"
    ? defaultURL.flatMap { Bundle(url: $0)?.bundleIdentifier } : CommandLine.arguments[1]
let process = bundle.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
var windows: [[String: Any]] = []
if let process {
    let app = AXUIElementCreateApplication(process.processIdentifier)
    let elements = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for element in elements {
        // Only inspect this test's compose windows, never the user's inbox or other drafts.
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        if CommandLine.arguments.count < 3 || title.contains(CommandLine.arguments[2]) {
            windows.append(read(element))
        }
    }
}
let result: [String: Any] = [
    "bundle": bundle ?? "", "pid": process?.processIdentifier ?? 0,
    "defaultMailPath": defaultURL?.path ?? "",
    "defaultMailBundle": defaultURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "",
    "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
    "windows": windows,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
