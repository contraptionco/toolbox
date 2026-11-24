import AppKit
import ApplicationServices
import Foundation

// Small, purpose-specific Accessibility client. It reads only mapped People
// sidebar rows and never reads Apple account files, caches, or the keychain.
// The parent process enforces a second, hard wall-clock timeout.
struct Input: Decodable { let names: [String] }
struct Row: Encodable { let name: String; let description: String; let selected: Bool }
struct Output: Encodable { var rows: [Row] = []; var error: String? = nil }

func emit(_ value: Output, code: Int32 = 0) -> Never {
    if let data = try? JSONEncoder().encode(value) {
        FileHandle.standardOutput.write(data)
    }
    exit(code)
}

let inputBytes = FileHandle.standardInput.readDataToEndOfFile()
guard inputBytes.count <= 32768,
      let input = try? JSONDecoder().decode(Input.self, from: inputBytes),
      (1...32).contains(input.names.count),
      input.names.allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") }) else {
    emit(Output(error: "invalid_request"), code: 64)
}
guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) else {
    emit(Output(error: "permission_required"), code: 77)
}

let deadline = Date().addingTimeInterval(15)
func runLoop(_ seconds: TimeInterval) {
    RunLoop.current.run(until: min(Date().addingTimeInterval(seconds), deadline))
}
let bundle = "com.apple.findmy"
var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
if running == nil {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/FindMy.app"), configuration: configuration) { app, _ in
        running = app
    }
    while running == nil && Date() < deadline.addingTimeInterval(-7) { runLoop(0.1) }
}
guard let process = running else { emit(Output(error: "source_unavailable"), code: 69) }
_ = process.activate(options: [])
let app = AXUIElementCreateApplication(process.processIdentifier)
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    guard Date() < deadline else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func string(_ element: AXUIElement, _ name: String) -> String {
    return attribute(element, name) as? String ?? ""
}
func walk(_ visit: (AXUIElement) -> Void) {
    var queue: [(AXUIElement, Int)] = [(app, 0)]
    var count = 0
    while !queue.isEmpty && count < 2500 && Date() < deadline {
        let (element, depth) = queue.removeLast()
        count += 1
        visit(element)
        guard depth < 20 else { continue }
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(200).map { ($0, depth + 1) })
        }
    }
}

// Select only the tab, never a person's row, a sharing action, or a context menu.
// Opening a row can expose a directions ETA that is not an observation time.
var peopleTab: AXUIElement?
for _ in 0..<4 {
    walk { element in
        let role = string(element, kAXRoleAttribute)
        guard [kAXRadioButtonRole, kAXButtonRole].contains(role) else { return }
        if string(element, kAXDescriptionAttribute) == "People" || string(element, kAXTitleAttribute) == "People" {
            peopleTab = element
        }
    }
    if peopleTab != nil { break }
    runLoop(0.25)
}
guard let tab = peopleTab else { emit(Output(error: "source_unavailable"), code: 69) }
let selected = (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
if !selected { _ = AXUIElementPerformAction(tab, kAXPressAction as CFString) }
runLoop(0.5)

let distanceField = try! NSRegularExpression(pattern: #",\s*(?:[<>≈]\s*)?\d+(?:[.,]\d+)?\s*(?:km|m|mi|ft)(?=,)"#, options: [.caseInsensitive])
func readRows() -> [Row] {
    var found: [Row] = []
    var seen = Set<String>()
    walk { element in
        guard string(element, kAXIdentifierAttribute).hasPrefix("ListEntityRow") else { return }
        let description = string(element, kAXDescriptionAttribute).precomposedStringWithCanonicalMapping
        guard description.count <= 2048 else { return }
        // The name ends at the structured distance field, not at the first
        // comma. Multiple possible distance fields make identity ambiguous.
        let boundaries = distanceField.matches(in: description, range: NSRange(description.startIndex..., in: description))
        guard boundaries.count == 1, let boundary = Range(boundaries[0].range, in: description) else { return }
        var completeName = String(description[..<boundary.lowerBound])
        let selected = (attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue
        if completeName.hasSuffix(", Open Details") {
            // This text can also be part of someone's actual name. Strip it
            // only when the row explicitly says it is selected.
            guard let selected else { return }
            if selected { completeName.removeLast(", Open Details".count) }
        }
        for name in input.names {
            let normalized = name.precomposedStringWithCanonicalMapping
            guard completeName == normalized else { continue }
            let key = normalized + "\u{0}" + description
            if seen.insert(key).inserted { found.append(Row(name: name, description: description, selected: selected ?? false)) }
        }
    }
    return found
}

var rows = readRows()
// Allow the app time to update after activation; paused rows remain paused.
// Only row descriptions are emitted, never accessibility action names or ETAs.
let settleUntil = min(Date().addingTimeInterval(3), deadline)
while Date() < settleUntil { runLoop(0.25) }
if Date() < deadline { rows = readRows() }
// A failed activation must not relabel an old Accessibility tree as refreshed.
guard process.isActive else { emit(Output(error: "source_unavailable"), code: 69) }
emit(Output(rows: rows))
