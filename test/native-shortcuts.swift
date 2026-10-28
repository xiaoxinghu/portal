// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon

// Real Carbon registrations through the core's shortcuts, as the Emacs
// bindings make them, delivering records to the core's notification pipe
// with no Portal view or launcher. Events go to the installed Carbon handler,
// not through the keyboard. A competing registration in this process stands
// in for another application that has a chord.
@main
struct ShortcutChecks {
    @MainActor static func main() {
        runChecks {
            _ = NSApplication.shared
            var descriptors: [Int32] = [0, 0]
            check(pipe(&descriptors) == 0)
            check(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
            check(portal_channel_connect(descriptors[1]))
            defer { portal_channel_connect(-1); close(descriptors[0]) }
            func records() -> String {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptors[0], &bytes, bytes.count)
                return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
            }
            /// Set CHORD in place of REPLACING; return its ID, or the error.
            func set(_ replacing: UInt64, _ chord: String) -> Result<UInt64, NativeError> {
                var id: UInt64 = 0
                var error = portal_text()
                let done = chord.withCString {
                    portal_shortcuts_set(replacing, portal_string(data: $0, length: chord.utf8.count), &id, &error)
                }
                defer { free(error.data) }
                return done ? .success(id) : .failure(.message(String(cString: error.data)))
            }
            func registered(_ chord: String) -> UInt64 {
                switch set(0, chord) {
                case .success(let id): return id
                case .failure(.message(let error)): fail("Cannot register \(chord): \(error)")
                }
            }
            func removed(_ id: UInt64) -> Bool {
                var error = portal_text()
                defer { free(error.data) }
                return portal_shortcuts_remove(id, &error)
            }
            func shortcuts() -> [[String: Any]] {
                var json = portal_text(), error = portal_text()
                check(portal_shortcuts_describe(&json, &error))
                defer { free(json.data) }
                return require(try JSONSerialization.jsonObject(
                    with: Data(bytes: json.data, count: json.length)) as? [[String: Any]])
            }
            /// The Carbon ID of shortcut ID: the core's hot key.
            func hotkey(_ id: UInt64) -> UInt32 {
                require(shortcuts().first { $0["id"] as? UInt64 == id }?["hotkey"] as? UInt32)
            }
            func event(_ hotkey: UInt32, _ pressed: Bool = true, at time: EventTime = GetCurrentEventTime()) {
                var event: EventRef?
                check(CreateEvent(nil, OSType(kEventClassKeyboard),
                                  UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),
                                  time, 0, &event) == noErr)
                let value = require(event)
                defer { ReleaseEvent(value) }
                var key = EventHotKeyID(signature: Hotkeys.signature, id: hotkey)
                check(SetEventParameter(value, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key) == noErr)
                _ = SendEventToEventTarget(value, GetApplicationEventTarget())
            }
            /// Press and release HOTKEY.
            func press(_ hotkey: UInt32) { event(hotkey); event(hotkey, false) }
            let modifiers = UInt32(controlKey | optionKey | cmdKey)
            /// Whether Carbon lets another registration have CODE with MODIFIERS.
            func available(_ code: UInt32, _ flags: UInt32 = modifiers) -> Bool {
                var reference: EventHotKeyRef?
                guard RegisterEventHotKey(code, flags, EventHotKeyID(signature: 0x54657374, id: 99),
                                          GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive),
                                          &reference) == noErr, let reference else { return false }
                check(UnregisterEventHotKey(reference) == noErr)
                return true
            }
            // Function keys F13 to F16, which a person's other apps are unlikely
            // to have registered with these modifiers.
            let (p, l, k, j) = (UInt32(105), UInt32(107), UInt32(113), UInt32(106))
            check(!Hotkeys.handling)

            // A registration takes its chord; a press sends one record however
            // long it is held.
            let first = registered("control-option-command-f13")
            check(!available(p) && Hotkeys.handling)
            let pKey = hotkey(first)
            event(pKey, at: GetCurrentEventTime() - 10)
            check(records().isEmpty, "An event from before the registration was delivered")
            event(pKey)
            event(pKey)
            check(records() == "shortcut \(first)\n")
            event(pKey, false)
            press(pKey)
            check(records() == "shortcut \(first)\n")
            press(UInt32(9999))
            check(records().isEmpty)

            // Another application's chord is refused, and nothing changes.
            var competing: EventHotKeyRef?
            check(RegisterEventHotKey(k, modifiers, EventHotKeyID(signature: 0x54657374, id: 1),
                                      GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive),
                                      &competing) == noErr)
            guard case .failure(.message(let refusal)) = set(first, "Control-Option-Command-F15") else {
                fail("Registered a chord another application has")
            }
            check(refusal.hasPrefix("Cannot register shortcut Control-Option-Command-F15: the system or another application has it (macOS "), refusal)
            guard case .failure = set(0, "Control-Option-Command-F15") else { fail("Registered a taken chord") }
            check(shortcuts().count == 1)
            press(pKey)
            check(records() == "shortcut \(first)\n")
            check(UnregisterEventHotKey(require(competing)) == noErr)

            // Two shortcuts are independent; one name cannot take another's chord.
            let second = registered("Control-Option-Command-F14")
            check(!available(l))
            guard case .failure = set(second, "Command-Control-Option-F13") else { fail("Took another's chord") }
            press(hotkey(second))
            press(pKey)
            check(records() == "shortcut \(second)\nshortcut \(first)\n")

            // The same chord keeps its Carbon registration under a new ID, and
            // restarts it: a press from before the set that Carbon delivers
            // only now, as when Emacs was busy, is stale.
            let early = GetCurrentEventTime()
            usleep(2000)
            guard case .success(let same) = set(first, "Command-Control-Option-F13") else { fail("Cannot set again") }
            check(same != first && hotkey(same) == pKey && !available(p))
            event(pKey, at: early)
            event(pKey, false)
            check(records().isEmpty, "A press from before the set reached Emacs")
            press(pKey)
            check(records() == "shortcut \(same)\n")
            // Another chord releases the old one once the new one is taken.
            guard case .success(let moved) = set(same, "Control-Option-Command-F16") else { fail("Cannot move") }
            check(available(p) && !available(j))
            press(pKey)
            check(records().isEmpty)
            press(hotkey(moved))
            check(records() == "shortcut \(moved)\n")

            // Removal releases only that chord, and repeating it is harmless.
            let lKey = hotkey(second)
            check(removed(second) && removed(second))
            check(available(l) && !available(j))
            press(lKey)
            check(records().isEmpty)
            check(removed(moved))
            check(available(j) && !Hotkeys.handling)

            for _ in 0..<20 {
                let a = registered("Control-Option-Command-F13"), b = registered("Control-Shift-F17")
                press(hotkey(a))
                press(hotkey(b))
                check(records() == "shortcut \(a)\nshortcut \(b)\n")
                let (aKey, bKey) = (hotkey(a), hotkey(b))
                check(removed(a) && removed(b) && removed(a))
                press(aKey)
                press(bKey)
                check(records().isEmpty)
                check(available(p) && available(UInt32(64), UInt32(controlKey | shiftKey)))
            }
            // Escape takes Control, Option or Command to be a shortcut, as
            // every key does, and then Carbon's Escape with those, and only that.
            if case .success = set(0, "Escape") { fail("A bare Escape registered") }
            let escapeCode = UInt32(kVK_Escape)
            check(available(escapeCode, 0) && available(escapeCode, UInt32(controlKey)))
            let escape = registered("Control-Escape")
            check(!available(escapeCode, UInt32(controlKey)) && available(escapeCode, 0))
            press(hotkey(escape))
            check(records() == "shortcut \(escape)\n")
            check(removed(escape) && available(escapeCode, UInt32(controlKey)))

            check(shortcuts().isEmpty && !Hotkeys.handling)
            print("Shortcut native checks passed: Carbon registration, conflicts, rebinding, release, stale and held events, pipe delivery without views, 20 set/remove cycles, Escape with a modifier")
        }
    }
}
