import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let project = Selection.english("project", identity: "app:1:0")!
check(Selection.english("  project\n plan  ", identity: "1")?.text == "project plan", "Normalize whitespace")
check(Selection.english("你好", identity: "1") == nil, "Ignore non-English text")
check(Selection.english("1234", identity: "1") == nil, "Ignore numbers without letters")
check(Selection.english("", identity: "1") == nil, "Ignore empty selection")
check(Selection.english(String(repeating: "a", count: 161), identity: "1") == nil, "Reject a long selection")
check(Selection.english(Array(repeating: "word", count: 21).joined(separator: " "), identity: "1") == nil, "Reject more than 20 words")
check(Selection.english("don't", identity: "1") != nil, "Allow apostrophes")

var gate = SelectionGate()
check(gate.update(project) == nil, "Do not speak intermediate selection")
check(gate.update(project) == "project", "Speak stable selection")
check(gate.update(project) == nil, "Do not loop speech while selected")
gate.interrupt()
check(gate.update(project) == nil, "Wait again after mouse movement or AX failure")
check(gate.update(project) == nil, "A transient AX failure must not repeat an old selection")
_ = gate.update(nil)
check(gate.update(project) == nil, "Debounce re-selection")
check(gate.update(project) == "project", "Re-selecting the same word speaks again")
let secondProject = Selection.english("project", identity: "app:1:20")!
check(gate.update(secondProject) == nil, "Debounce a new occurrence")
check(gate.update(secondProject) == "project", "Same word at another location speaks")
let otherApp = Selection.english("project", identity: "app:2:0")!
check(gate.update(otherApp) == nil, "Debounce app switch")
check(gate.update(otherApp) == "project", "Same word in another app speaks")
gate.reset()
check(gate.update(project) == nil, "Reset on pause")
check(gate.update(project) == "project", "Resume speaks selection")
print("PASS: selection filtering, stable selection, duplicate prevention, re-selection, app switching, pause/resume")
