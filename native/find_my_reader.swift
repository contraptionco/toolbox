import AppKit
import ApplicationServices
import Foundation

// Older Find My versions combine name, place, age, and distance into one
// unstructured label. A prefix finds a candidate only; identity comes from the
// separately selected detail card's exact name and that same row's AXSelected.
struct LegacyFindMyRow {
    struct Fixture: Decodable {
        let name: String
        let description: String
        let detailName: String?
        let candidateCount: Int
        let selected: Bool
        let wasSelected: Bool
        let hadMatchingHeader: Bool
    }
    static let suffix = try! NSRegularExpression(
        pattern: #",\s*(Now|\d+\s+(?:min(?:ute)?s?\.?|hr\.?|hours?)\s+ago|Paused),\s*((?:[<>≈]\s*)?\d+(?:[.,]\d+)?\s*(?:km|m|mi|ft))\z"#,
        options: [.caseInsensitive])

    static func isCandidate(name: String, description: String) -> Bool {
        let normalized = description.precomposedStringWithCanonicalMapping
        return normalized.count <= 2048 &&
            normalized.hasPrefix(name.precomposedStringWithCanonicalMapping + ",") &&
            suffix.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }

    static func canonicalDescription(from fixture: Fixture) -> String? {
        let name = fixture.name.precomposedStringWithCanonicalMapping
        let text = fixture.description.precomposedStringWithCanonicalMapping
        guard fixture.candidateCount == 1, fixture.selected,
              fixture.detailName?.precomposedStringWithCanonicalMapping == name,
              !(fixture.hadMatchingHeader && !fixture.wasSelected),
              isCandidate(name: name, description: text),
              let match = suffix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let boundary = Range(match.range, in: text),
              let age = Range(match.range(at: 1), in: text),
              let distance = Range(match.range(at: 2), in: text) else { return nil }
        let labelStart = text.index(text.startIndex, offsetBy: name.count + 1)
        guard labelStart < boundary.lowerBound else { return nil }
        let label = text[labelStart..<boundary.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        // Reorder only the verified fields. Ruby applies its existing freshness,
        // unavailable-label, ambiguity, and paused checks to this canonical row.
        return "\(name), \(text[distance]), \(label), \(text[age])"
    }
}

#if MANUAL_LOCATION_TEST
let fixtures = try JSONDecoder().decode([LegacyFindMyRow.Fixture].self, from: FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(try JSONEncoder().encode(fixtures.map { LegacyFindMyRow.canonicalDescription(from: $0) }))
#else

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
AXUIElementSetMessagingTimeout(app, 0.15)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    guard Date() < deadline else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func string(_ element: AXUIElement, _ name: String) -> String {
    return attribute(element, name) as? String ?? ""
}
guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
      windows.count == 1, let window = windows.first else { emit(Output(error: "source_unavailable"), code: 69) }
func walk(_ visit: (AXUIElement) -> Void) {
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var visited: [CFHashCode: [AXUIElement]] = [:]
    var count = 0
    while !queue.isEmpty && count < 2500 && Date() < deadline {
        let (element, depth) = queue.removeLast()
        let hash = CFHash(element)
        guard !(visited[hash] ?? []).contains(where: { CFEqual($0, element) }) else { continue }
        visited[hash, default: []].append(element)
        count += 1
        visit(element)
        guard depth < 20 else { continue }
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(200).map { ($0, depth + 1) })
        }
    }
}

// Select the People tab. Legacy rows may also require opening their read-only
// detail card for exact identity; no sharing action or context menu is invoked.
// A directions ETA in that card is never used as an observation time.
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
guard (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true else { emit(Output(error: "source_unavailable"), code: 69) }

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

func isSelected(_ element: AXUIElement) -> Bool {
    return (attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
}

func parent(_ element: AXUIElement) -> AXUIElement? {
    guard let value = attribute(element, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func legacyListContainer(_ element: AXUIElement) -> AXUIElement? {
    guard let row = parent(element), string(row, kAXRoleAttribute) == kAXGroupRole,
          let list = parent(row), string(list, kAXRoleAttribute) == kAXGroupRole else { return nil }
    // The People list advertises this attribute but returns no value while
    // nothing is selected. Discover its supported structure before selection;
    // require the actual selected-child relationship when verifying identity.
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(list, &names) == .success,
          (names as? [String])?.contains(kAXSelectedChildrenAttribute) == true else { return nil }
    return list
}

func legacyListSelection(_ element: AXUIElement) -> [AXUIElement]? {
    guard let list = legacyListContainer(element) else { return nil }
    return attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement]
}

func legacyRowIsSelected(_ element: AXUIElement) -> Bool {
    guard isSelected(element), let row = parent(element), isSelected(row),
          let selection = legacyListSelection(element) else { return false }
    return selection.contains(where: { CFEqual($0, row) })
}

func hasLegacyDetailContainer(_ element: AXUIElement) -> Bool {
    guard let container = parent(element), string(container, kAXRoleAttribute) == kAXGroupRole else { return false }
    // Observed legacy detail cards group the title with action buttons and a
    // contact link. Sidebar rows and map labels do not have this structure.
    // Do not walk upward into the whole window and accept an unrelated label.
    var queue: [(AXUIElement, Int)] = [(container, 0)]
    var buttons = 0
    var links = 0
    var count = 0
    while !queue.isEmpty && count < 160 && Date() < deadline {
        let (current, depth) = queue.removeLast()
        count += 1
        let role = string(current, kAXRoleAttribute)
        if role == kAXTabGroupRole || role == kAXRadioButtonRole { return false }
        if role == kAXButtonRole { buttons += 1 }
        if role == "AXLink" { links += 1 }
        if depth < 5, let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(50).map { ($0, depth + 1) })
        }
    }
    return queue.isEmpty && buttons >= 2 && links >= 1
}

func exactDetailHeaders(_ name: String) -> [AXUIElement] {
    var headers: [AXUIElement] = []
    let normalized = name.precomposedStringWithCanonicalMapping
    walk { element in
        guard string(element, kAXRoleAttribute) == kAXStaticTextRole,
              !isSelected(element),
              string(element, kAXDescriptionAttribute).precomposedStringWithCanonicalMapping == normalized,
              let labels = attribute(element, "AXUserInputLabels") as? [String],
              labels.contains(where: { $0.precomposedStringWithCanonicalMapping == normalized }),
              hasLegacyDetailContainer(element) else { return }
        headers.append(element)
    }
    return headers
}

func legacyCandidates(_ name: String) -> [AXUIElement] {
    var candidates: [AXUIElement] = []
    walk { element in
        guard string(element, kAXRoleAttribute) == kAXStaticTextRole,
              !string(element, kAXIdentifierAttribute).hasPrefix("ListEntityRow"),
              legacyListContainer(element) != nil,
              LegacyFindMyRow.isCandidate(name: name, description: string(element, kAXDescriptionAttribute)) else { return }
        candidates.append(element)
    }
    return candidates
}

func readLegacyRow(_ name: String) -> Row? {
    let candidates = legacyCandidates(name)
    guard candidates.count == 1, let candidate = candidates.first else { return nil }
    let wasSelected = legacyRowIsSelected(candidate)
    let previousHeaders = exactDetailHeaders(name)
    guard previousHeaders.count <= 1 else { return nil }
    let hadMatchingHeader = !previousHeaders.isEmpty
    // An old matching header must never validate selecting another candidate.
    guard !hadMatchingHeader || wasSelected else { return nil }
    if !wasSelected || !hadMatchingHeader {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(candidate, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true else { return nil }
        // Press only this candidate's primary row action. An action result alone
        // is not identity evidence; observe selection and the new header below.
        _ = AXUIElementPerformAction(candidate, kAXPressAction as CFString)
    }
    let settle = min(Date().addingTimeInterval(2), deadline)
    var selectedCandidate: AXUIElement?
    while Date() < settle {
        // Selecting a row can replace its Accessibility element. Discover the
        // current unique row, then prove its list selection and exact card name;
        // do not wait on a stale pre-selection handle.
        let fresh = legacyCandidates(name)
        if fresh.count == 1, legacyRowIsSelected(fresh[0]), exactDetailHeaders(name).count == 1 {
            selectedCandidate = fresh[0]
            break
        }
        runLoop(0.15)
    }
    guard Date() < deadline, let verified = selectedCandidate else { return nil }
    runLoop(0.25)
    // Re-read the selected row after the detail transition. Confirm that the
    // same candidate is still unique and selected and the header remains exact.
    let current = legacyCandidates(name)
    guard current.count == 1, CFEqual(current[0], verified), legacyRowIsSelected(verified),
          exactDetailHeaders(name).count == 1 else { return nil }
    let description = string(verified, kAXDescriptionAttribute)
    let fixture = LegacyFindMyRow.Fixture(name: name, description: description,
        detailName: name, candidateCount: current.count, selected: legacyRowIsSelected(verified),
        wasSelected: wasSelected, hadMatchingHeader: hadMatchingHeader)
    guard let canonical = LegacyFindMyRow.canonicalDescription(from: fixture),
          legacyRowIsSelected(verified), exactDetailHeaders(name).count == 1 else { return nil }
    return Row(name: name, description: canonical, selected: false)
}

var rows = readRows()
// Allow the app time to update after activation; paused rows remain paused.
// Only row descriptions are emitted, never accessibility action names or ETAs.
let settleUntil = min(Date().addingTimeInterval(3), deadline)
while Date() < settleUntil { runLoop(0.25) }
if Date() < deadline { rows = readRows() }
for name in input.names where !rows.contains(where: { $0.name == name }) && Date() < deadline {
    if let row = readLegacyRow(name) { rows.append(row) }
}
// A failed activation must not relabel an old Accessibility tree as refreshed.
guard process.isActive else { emit(Output(error: "source_unavailable"), code: 69) }
emit(Output(rows: rows))
#endif
