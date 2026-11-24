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

struct FindMyInfoAddress {
    struct Fixture: Decodable {
        let name: String
        let header: String
        let address: String
        let sidebarAge: String
        let detailAge: String
        let selected: Bool
        let panelCount: Int
    }

    static func age(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare("Now") == .orderedSame { return 0 }
        let pattern = #"\A(\d+)\s+(min(?:ute)?s?\.?|hr\.?|hours?)\s+ago\z"#
        let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Int(text[amountRange]), amount <= 7200 else { return nil }
        let seconds = amount * (text[unitRange].lowercased().hasPrefix("h") ? 3600 : 60)
        return seconds <= 7200 ? seconds : nil
    }

    static func validated(_ fixture: Fixture) -> String? {
        guard fixture.selected, fixture.panelCount == 1,
              fixture.name.precomposedStringWithCanonicalMapping == fixture.header.precomposedStringWithCanonicalMapping,
              let sidebarAge = age(fixture.sidebarAge), age(fixture.detailAge) == sidebarAge,
              !fixture.address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let address = fixture.address.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // A city or place nickname is not a street address. Only preserve the
        // observed numbered-street format; unsupported formats stay optional.
        guard address.utf8.count <= 240,
              address.range(of: #"\A\d+[A-Za-z-]*\s+[^,]*\b(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Drive|Dr|Broadway|Place|Pl|Boulevard|Blvd|Way|Court|Ct|Parkway|Pkwy|Square|Sq|Terrace|Ter|Highway|Hwy)\b[^,]*,\s*[^,]+,\s*[^,]+\z"#,
                  options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return address
    }
}

#if MANUAL_LOCATION_INFO_TEST
let fixtures = try JSONDecoder().decode([FindMyInfoAddress.Fixture].self, from: FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(try JSONEncoder().encode(fixtures.map { FindMyInfoAddress.validated($0) }))
#elseif MANUAL_LOCATION_TEST
let fixtures = try JSONDecoder().decode([LegacyFindMyRow.Fixture].self, from: FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(try JSONEncoder().encode(fixtures.map { LegacyFindMyRow.canonicalDescription(from: $0) }))
#else

// Small, purpose-specific Accessibility client. It reads only mapped People or
// Devices sidebar rows and never reads Apple account files, caches, or the keychain.
// The parent process enforces a second, hard wall-clock timeout.
struct Input: Decodable { let names: [String]; let source: String? }
struct Row: Encodable { let name: String; let description: String; let selected: Bool; let source: String; var address: String? = nil }
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
      input.names.allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") }),
      input.source == nil || ["person", "device"].contains(input.source!) else {
    emit(Output(error: "invalid_request"), code: 64)
}
let sourceKind = input.source ?? "person"
let tabName = sourceKind == "device" ? "Devices" : "People"
guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) else {
    emit(Output(error: "permission_required"), code: 77)
}

var deadline = Date().addingTimeInterval(15)
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
      windows.count == 1, let initialWindow = windows.first else { emit(Output(error: "source_unavailable"), code: 69) }
var window = initialWindow
func refreshWindow() -> Bool {
    guard let current = attribute(app, kAXWindowsAttribute) as? [AXUIElement], current.count == 1 else { return false }
    window = current[0]
    return true
}
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

// Select only the explicitly requested source tab. Legacy rows may require opening their read-only
// detail card for exact identity; no sharing action or context menu is invoked.
// A directions ETA in that card is never used as an observation time.
// A previously opened read-only Info panel hides the source tabs. Dismiss only
// a verified panel whose exact header is one of this invocation's mappings.
var existingInfo: [InfoPanel] = []
walk { element in
    guard input.names.contains(where: { $0.precomposedStringWithCanonicalMapping == string(element, kAXDescriptionAttribute).precomposedStringWithCanonicalMapping }),
          let panel = infoPanel(element) else { return }
    if !existingInfo.contains(where: { CFEqual($0.container, panel.container) }) { existingInfo.append(panel) }
}
if existingInfo.count == 1 { _ = dismissInfo(existingInfo[0]); _ = refreshWindow() }
var sourceTab: AXUIElement?
for _ in 0..<4 {
    _ = refreshWindow()
    walk { element in
        let role = string(element, kAXRoleAttribute)
        guard [kAXRadioButtonRole, kAXButtonRole].contains(role) else { return }
        if string(element, kAXDescriptionAttribute) == tabName || string(element, kAXTitleAttribute) == tabName {
            sourceTab = element
        }
    }
    if sourceTab != nil { break }
    runLoop(0.25)
}
guard let initialTab = sourceTab else { emit(Output(error: "source_unavailable"), code: 69) }
var tab = initialTab
let selected = (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
if !selected { _ = AXUIElementPerformAction(tab, kAXPressAction as CFString) }
runLoop(0.5)
guard (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true else { emit(Output(error: "source_unavailable"), code: 69) }

let distanceField = try! NSRegularExpression(pattern: #",\s*(?:[<>≈]\s*)?\d+(?:[.,]\d+)?\s*(?:km|m|mi|ft)(?=,)"#, options: [.caseInsensitive])
func readRows() -> [Row] {
    // Only the observed legacy device layout below is supported. Do not infer a
    // newer Devices layout from a visually similar People row.
    guard sourceKind == "person", (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true else { return [] }
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
            if seen.insert(key).inserted { found.append(Row(name: name, description: description, selected: selected ?? false, source: sourceKind)) }
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

func scopedElements(_ root: AXUIElement) -> [AXUIElement]? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited: [CFHashCode: [AXUIElement]] = [:]
    var result: [AXUIElement] = []
    while !queue.isEmpty && result.count < 200 && Date() < deadline {
        let (element, depth) = queue.removeLast()
        let hash = CFHash(element)
        if (visited[hash] ?? []).contains(where: { CFEqual($0, element) }) { continue }
        visited[hash, default: []].append(element)
        result.append(element)
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
            guard depth < 12, children.count <= 100 else { return nil }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
    }
    return queue.isEmpty && Date() < deadline ? result : nil
}

struct InfoPanel {
    let header: AXUIElement
    let container: AXUIElement
    let name: String
    let address: String?
    let age: String?
}

func dismissInfo(_ panel: InfoPanel) -> Bool {
    guard let current = infoPanel(panel.header), CFEqual(current.container, panel.container), current.name == panel.name else { return false }
    var actions: CFArray?
    guard AXUIElementCopyActionNames(panel.container, &actions) == .success,
          (actions as? [String])?.contains(kAXCancelAction) == true else { return false }
    _ = AXUIElementPerformAction(panel.container, kAXCancelAction as CFString)
    runLoop(0.1)
    // The caller must observe the restored source view; AX action success is
    // not evidence that the animated popup has finished closing.
    return true
}

func infoPanel(_ header: AXUIElement) -> InfoPanel? {
    guard string(header, kAXRoleAttribute) == kAXStaticTextRole,
          string(header, kAXIdentifierAttribute) == "PrimaryLabel",
          let first = parent(header), string(first, kAXRoleAttribute) == kAXGroupRole,
          let second = parent(first), string(second, kAXRoleAttribute) == kAXGroupRole,
          let popover = parent(second), string(popover, kAXRoleAttribute) == "AXPopover",
          let elements = scopedElements(popover),
          !elements.contains(where: { [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXRadioButtonRole, kAXMenuRole].contains(string($0, kAXRoleAttribute)) }),
          elements.contains(where: {
              guard string($0, kAXRoleAttribute) == kAXButtonRole else { return false }
              let description = string($0, kAXDescriptionAttribute)
              return description == "Directions" || description.hasPrefix("Directions,")
          }) else { return nil }
    func fields(_ identifier: String) -> [AXUIElement] {
        elements.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole && string($0, kAXIdentifierAttribute) == identifier }
    }
    let primary = fields("PrimaryLabel")
    let secondary = fields("SecondaryLabel")
    let tertiary = fields("TertiaryLabel")
    guard primary.count == 1, CFEqual(primary[0], header), secondary.count <= 1, tertiary.count <= 1 else { return nil }
    return InfoPanel(header: header, container: popover, name: string(header, kAXDescriptionAttribute).precomposedStringWithCanonicalMapping,
        address: secondary.first.map { string($0, kAXDescriptionAttribute) },
        age: tertiary.first.map { string($0, kAXDescriptionAttribute) })
}

func legacyListContainer(_ element: AXUIElement) -> AXUIElement? {
    guard let row = parent(element), string(row, kAXRoleAttribute) == kAXGroupRole,
          let list = parent(row), string(list, kAXRoleAttribute) == kAXGroupRole else { return nil }
    // The People and Devices lists advertise this attribute but return no value while
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
    // Observed legacy People and Devices detail cards group the title with
    // action buttons and a link. Sidebar rows and map labels lack this structure.
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
              (hasLegacyDetailContainer(element) || infoPanel(element) != nil) else { return }
        headers.append(element)
    }
    return headers
}

func expandInfo(_ name: String, selectedRow: AXUIElement) -> InfoPanel? {
    let headers = exactDetailHeaders(name)
    guard headers.count == 1, legacyRowIsSelected(selectedRow) else { return nil }
    if let existing = infoPanel(headers[0]) { return existing }
    guard let card = parent(headers[0]), let children = attribute(card, kAXChildrenAttribute) as? [AXUIElement], children.count <= 100 else { return nil }
    // More Info is a direct sibling of the verified bubble title. Do not
    // descend into the surrounding map or pick a control by screen position.
    var controls: [AXUIElement] = []
    for child in children where string(child, kAXRoleAttribute) == kAXButtonRole && string(child, kAXDescriptionAttribute) == "More Info" {
        if !controls.contains(where: { CFEqual($0, child) }) { controls.append(child) }
    }
    guard controls.count == 1, exactDetailHeaders(name).count == 1, legacyRowIsSelected(selectedRow) else { return nil }
    var actions: CFArray?
    guard AXUIElementCopyActionNames(controls[0], &actions) == .success,
          (actions as? [String])?.contains(kAXPressAction) == true else { return nil }
    // This only opens the selected source's read-only information. Never press
    // a setting, sharing control, directions action, or device command.
    _ = AXUIElementPerformAction(controls[0], kAXPressAction as CFString)
    let settle = min(Date().addingTimeInterval(1.5), deadline)
    while Date() < settle {
        if !refreshWindow() { runLoop(0.1); continue }
        let current = exactDetailHeaders(name)
        if current.count == 1, let panel = infoPanel(current[0]) { return panel }
        runLoop(0.1)
    }
    return nil
}

func readAndCloseInfo(_ name: String, selectedRow: AXUIElement) -> InfoPanel? {
    // Leave enough time to close the modal read-only view and revalidate its
    // sidebar selection. Source reads must never depend on a hidden old tree.
    guard Date() < deadline.addingTimeInterval(-5) else { return nil }
    let hardDeadline = deadline
    deadline = hardDeadline.addingTimeInterval(-3)
    let captured = expandInfo(name, selectedRow: selectedRow)
    let same = captured.flatMap { infoPanel($0.header) }
    let stable = captured.flatMap { panel in
        same.map { CFEqual($0.container, panel.container) && $0.name == panel.name && $0.address == panel.address && $0.age == panel.age }
    } == true
    // Address discovery has a shorter budget than cleanup. Restore the hard
    // deadline even when parsing failed, then close a verified mapped panel.
    deadline = hardDeadline
    var cleanup = captured
    if cleanup == nil, refreshWindow() {
        let current = exactDetailHeaders(name)
        if current.count == 1 { cleanup = infoPanel(current[0]) }
    }
    guard let panel = cleanup, panel.name == name.precomposedStringWithCanonicalMapping else { return nil }
    guard dismissInfo(panel) else { return nil }
    // The popup temporarily replaces the accessible window/tab handles.
    let settle = min(Date().addingTimeInterval(1.5), deadline)
    var restoredTab: AXUIElement?
    while Date() < settle {
        if !refreshWindow() { runLoop(0.1); continue }
        var restoredTabs: [AXUIElement] = []
        walk { element in
            if [kAXRadioButtonRole, kAXButtonRole].contains(string(element, kAXRoleAttribute)),
               string(element, kAXDescriptionAttribute) == tabName { restoredTabs.append(element) }
        }
        if restoredTabs.count == 1, (attribute(restoredTabs[0], kAXValueAttribute) as? NSNumber)?.boolValue == true {
            restoredTab = restoredTabs[0]
            break
        }
        runLoop(0.1)
    }
    guard let restoredTab else { return nil }
    tab = restoredTab
    return stable ? panel : nil
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
    guard (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true else { return nil }
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
    let capturedInfo = readAndCloseInfo(name, selectedRow: verified)
    runLoop(0.15)
    // Expanding Info can replace accessibility handles. Establish the current
    // unique selected row and its exact header again before reading any fields.
    let finalRows = legacyCandidates(name)
    let finalHeaders = exactDetailHeaders(name)
    guard finalRows.count == 1, finalHeaders.count == 1, legacyRowIsSelected(finalRows[0]) else { return nil }
    let finalRow = finalRows[0]
    let description = string(finalRow, kAXDescriptionAttribute)
    let fixture = LegacyFindMyRow.Fixture(name: name, description: description,
        detailName: name, candidateCount: finalRows.count, selected: legacyRowIsSelected(finalRow),
        wasSelected: wasSelected, hadMatchingHeader: hadMatchingHeader)
    guard let canonical = LegacyFindMyRow.canonicalDescription(from: fixture) else { return nil }
    var address: String?
    if let panel = capturedInfo, let value = panel.address, let age = panel.age,
       let match = LegacyFindMyRow.suffix.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)),
       let ageRange = Range(match.range(at: 1), in: description) {
        address = FindMyInfoAddress.validated(.init(name: name,
            header: panel.name, address: value,
            sidebarAge: String(description[ageRange]), detailAge: age,
            selected: legacyRowIsSelected(finalRow), panelCount: finalHeaders.count))
    }
    let checkedRows = legacyCandidates(name)
    let checkedHeaders = exactDetailHeaders(name)
    guard checkedRows.count == 1, CFEqual(checkedRows[0], finalRow), legacyRowIsSelected(finalRow),
          string(finalRow, kAXDescriptionAttribute) == description,
          checkedHeaders.count == 1, CFEqual(checkedHeaders[0], finalHeaders[0]),
          (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true else { return nil }
    return Row(name: name, description: canonical, selected: false, source: sourceKind, address: address)
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
guard process.isActive, (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true else { emit(Output(error: "source_unavailable"), code: 69) }
emit(Output(rows: rows))
#endif
