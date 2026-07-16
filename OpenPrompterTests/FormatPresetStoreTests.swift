//
//  FormatPresetStoreTests.swift
//  OpenPrompterTests
//
//  Covers the on-device Format preset store + persistence (V3 Design 04):
//    - fresh store returns three presets with the shipped default prompts,
//      isEdited == false
//    - override persistence: setting a prompt writes the override key and
//      isEdited flips true
//    - reset-to-default writes "" so a future shipped-default change reaches
//      the user, and the resolved prompt equals the code default
//    - custom name / prompt round-trip; empty name resolves to "Custom"
//    - the iCloud-mirror key list includes the prompt keys and EXCLUDES the
//      coach-mark key
//    - labs.format registration default is DEBUG-on
//
//  Scaffolding mirrors RecordingAspectTests: snapshot + restore the touched
//  standard-defaults keys so the rest of the suite sees pristine state.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class FormatPresetStoreTests: XCTestCase {

    private let touchedKeys: [String] = [
        PrefKey.formatPromptFormatOverride.rawValue,
        PrefKey.formatPromptCleanupOverride.rawValue,
        PrefKey.formatPromptCustom.rawValue,
        PrefKey.formatCustomName.rawValue,
        PrefKey.labsFormat.rawValue
    ]

    private var savedValues: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let store = UserDefaults.standard
        savedValues.removeAll(keepingCapacity: true)
        for key in touchedKeys {
            savedValues[key] = store.object(forKey: key)
            store.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let store = UserDefaults.standard
        for key in touchedKeys {
            if case let .some(value?) = savedValues[key] {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        savedValues.removeAll()
        super.tearDown()
    }

    // MARK: - Defaults

    func testFreshStoreReturnsThreeDefaultPresets() {
        let store = FormatPresetStore()
        let presets = store.presets
        XCTAssertEqual(presets.count, 3)
        XCTAssertEqual(presets.map(\.kind), [.format, .cleanup, .custom])

        for preset in presets {
            XCTAssertFalse(preset.isEdited,
                           "Fresh \(preset.kind) preset must not be flagged edited.")
            XCTAssertEqual(preset.prompt,
                           FormatPreset.defaultPrompt(for: preset.kind),
                           "Fresh \(preset.kind) prompt must equal the shipped default.")
            XCTAssertFalse(preset.prompt.isEmpty)
        }
    }

    func testDefaultNamesAndPromptsAreStable() {
        XCTAssertEqual(FormatPreset.defaultName(for: .format), "Format")
        XCTAssertEqual(FormatPreset.defaultName(for: .cleanup), "Cleanup")
        XCTAssertEqual(FormatPreset.defaultName(for: .custom), "Custom")
        XCTAssertTrue(FormatPreset.Defaults.format.contains("WITHOUT changing the words"),
                      "The Format default must carry the do-not-change-words guardrail.")
    }

    // MARK: - Override persistence

    func testSettingPromptPersistsOverrideAndFlagsEdited() {
        let store = FormatPresetStore()
        store.setPrompt("My custom format rules", for: .format)

        // Persisted to the override key.
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: PrefKey.formatPromptFormatOverride.rawValue),
            "My custom format rules"
        )
        // Resolved prompt reflects the override + isEdited flips true.
        let refreshed = FormatPresetStore().preset(for: .format)
        XCTAssertEqual(refreshed.prompt, "My custom format rules")
        XCTAssertTrue(refreshed.isEdited)
    }

    // MARK: - Reset-to-default writes empty

    func testResetToDefaultWritesEmptyAndResolvesToCodeDefault() {
        let store = FormatPresetStore()
        store.setPrompt("Edited cleanup", for: .cleanup)
        XCTAssertTrue(store.preset(for: .cleanup).isEdited)

        store.resetToDefault(.cleanup)

        // The stored override is now "" so a future shipped-default change
        // reaches this user (NOT frozen to the current default string).
        let stored = UserDefaults.standard.string(forKey: PrefKey.formatPromptCleanupOverride.rawValue)
        XCTAssertEqual(stored, "", "Reset must clear the override to empty, not freeze the default string.")

        let refreshed = FormatPresetStore().preset(for: .cleanup)
        XCTAssertEqual(refreshed.prompt, FormatPreset.Defaults.cleanup)
        XCTAssertFalse(refreshed.isEdited)
    }

    func testSettingDefaultStringClearsOverride() {
        let store = FormatPresetStore()
        // Writing the exact shipped default must clear the override, not
        // freeze it — same "" == default rule.
        store.setPrompt(FormatPreset.Defaults.format, for: .format)
        let stored = UserDefaults.standard.string(forKey: PrefKey.formatPromptFormatOverride.rawValue)
        XCTAssertEqual(stored, "")
        XCTAssertFalse(store.preset(for: .format).isEdited)
    }

    // MARK: - Custom name / prompt round-trip

    func testCustomNameRoundTripAndEmptyResolvesToCustom() {
        let store = FormatPresetStore()
        // Default name is "Custom" when nothing stored.
        XCTAssertEqual(store.preset(for: .custom).name, "Custom")

        store.setCustomName("Punchy")
        XCTAssertEqual(FormatPresetStore().preset(for: .custom).name, "Punchy")

        // Clearing the name resolves back to "Custom".
        store.setCustomName("   ")
        XCTAssertEqual(FormatPresetStore().preset(for: .custom).name, "Custom")
    }

    func testCustomPromptRoundTrip() {
        let store = FormatPresetStore()
        XCTAssertEqual(store.preset(for: .custom).prompt, FormatPreset.Defaults.custom)
        XCTAssertFalse(store.preset(for: .custom).isEdited)

        store.setPrompt("Just fix spacing.", for: .custom)
        let refreshed = FormatPresetStore().preset(for: .custom)
        XCTAssertEqual(refreshed.prompt, "Just fix spacing.")
        XCTAssertTrue(refreshed.isEdited)
    }

    // MARK: - iCloud mirror + registration default

    func testMirrorKeyListIncludesPromptKeysExcludesCoachMark() {
        // Reach the private mirroredKeys list through the pull/push behavior:
        // set a prompt key, push, and assert it landed in the ubiquitous
        // store; assert the coach-mark key does NOT.
        let kv = NSUbiquitousKeyValueStore.default
        kv.removeObject(forKey: PrefKey.formatPromptFormatOverride.rawValue)
        kv.removeObject(forKey: PrefKey.coachMarkFormatShown.rawValue)

        UserDefaults.standard.set("mirror me", forKey: PrefKey.formatPromptFormatOverride.rawValue)
        UserDefaults.standard.set(true, forKey: PrefKey.coachMarkFormatShown.rawValue)

        UbiquitousPrefsMirror.pushToCloud()

        XCTAssertEqual(kv.string(forKey: PrefKey.formatPromptFormatOverride.rawValue),
                       "mirror me",
                       "Format prompt override must be mirrored to iCloud KVS.")
        XCTAssertNil(kv.object(forKey: PrefKey.coachMarkFormatShown.rawValue),
                     "The Format coach-mark flag must stay device-local (not mirrored).")

        // Cleanup KVS so we don't leave test junk in the ubiquitous store.
        kv.removeObject(forKey: PrefKey.formatPromptFormatOverride.rawValue)
        UserDefaults.standard.removeObject(forKey: PrefKey.coachMarkFormatShown.rawValue)
    }

    func testLabsFormatRegistrationDefaultIsDebugOn() {
        // Matches the other in-progress labs flags' pre-graduation shape.
        #if DEBUG
        XCTAssertEqual(PrefKey.labsFormat.defaultValue as? Bool, true,
                       "labs.format must default ON in DEBUG so the founder can dogfood.")
        #else
        XCTAssertEqual(PrefKey.labsFormat.defaultValue as? Bool, false,
                       "labs.format must default OFF in Release until it graduates.")
        #endif
    }
}
