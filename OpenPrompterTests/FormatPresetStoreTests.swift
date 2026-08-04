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
//  HERMETICITY RULE (learned the hard way): the mirror tests below must NEVER
//  touch `NSUbiquitousKeyValueStore.default` or `UserDefaults.standard`. The
//  real ubiquitous store silently no-ops when no iCloud account is signed in,
//  so an assertion against it passes on a long-lived simulator and fails on
//  every clean machine — which is exactly how an outside contributor's first
//  clone of this repo greeted them with a red suite (2026-08-04). Use the
//  injected `FakeKeyValueStore` + a scratch `UserDefaults(suiteName:)`.
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

    /// Distinct suite per call so writes from one test can't leak into
    /// another — matches the `RemoteBindingStoreTests` convention.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "FormatPresetStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// In-memory stand-in for `NSUbiquitousKeyValueStore`.
    ///
    /// The real store silently no-ops with no iCloud account signed in, so the
    /// previous version of this test — which pushed to
    /// `NSUbiquitousKeyValueStore.default` and read back — failed on any clean
    /// machine while passing on a long-lived simulator. Reported by an outside
    /// contributor who cloned the repo (2026-08-04). Never assert mirror
    /// behavior against the real store.
    private final class FakeKeyValueStore: KeyValueStoring {
        private(set) var storage: [String: Any] = [:]
        private(set) var synchronizeCount = 0

        func object(forKey aKey: String) -> Any? { storage[aKey] }

        func set(_ anObject: Any?, forKey aKey: String) {
            if let anObject {
                storage[aKey] = anObject
            } else {
                storage.removeValue(forKey: aKey)
            }
        }

        @discardableResult
        func synchronize() -> Bool {
            synchronizeCount += 1
            return true
        }
    }

    /// The list itself is the contract, so assert it directly — no I/O, no
    /// ambient state, no inference from a cloud round-trip.
    func testMirrorKeyListIncludesPromptKeysExcludesCoachMark() {
        let keys = UbiquitousPrefsMirror.mirroredKeys

        XCTAssertTrue(keys.contains(.formatPromptFormatOverride),
                      "Format prompt override must mirror across devices.")
        XCTAssertTrue(keys.contains(.formatPromptCleanupOverride),
                      "Cleanup prompt override must mirror across devices.")
        XCTAssertTrue(keys.contains(.formatPromptCustom),
                      "Custom prompt must mirror across devices.")
        XCTAssertTrue(keys.contains(.formatCustomName),
                      "The custom preset name travels with its prompt.")

        XCTAssertFalse(keys.contains(.coachMarkFormatShown),
                       "The Format coach-mark flag must stay device-local.")
        XCTAssertFalse(keys.contains(.labsFormat),
                       "The Format labs flag is a per-device capability toggle.")
    }

    /// Push behavior, exercised hermetically against a fake store + a scratch
    /// defaults suite. Covers what the old cloud round-trip intended to.
    func testPushToCloudMirrorsPromptKeyButNotCoachMark() {
        let defaults = makeDefaults()
        let kv = FakeKeyValueStore()

        defaults.set("mirror me", forKey: PrefKey.formatPromptFormatOverride.rawValue)
        defaults.set(true, forKey: PrefKey.coachMarkFormatShown.rawValue)

        UbiquitousPrefsMirror.pushToCloud(to: kv, from: defaults)

        XCTAssertEqual(kv.object(forKey: PrefKey.formatPromptFormatOverride.rawValue) as? String,
                       "mirror me",
                       "Format prompt override must be pushed to the ubiquitous store.")
        XCTAssertNil(kv.object(forKey: PrefKey.coachMarkFormatShown.rawValue),
                     "The Format coach-mark flag must never leave the device.")
        XCTAssertEqual(kv.synchronizeCount, 1, "Push should synchronize exactly once.")
    }

    /// Pull direction — previously untested entirely.
    func testPullFromCloudWritesMirroredKeysIntoDefaults() {
        let defaults = makeDefaults()
        let kv = FakeKeyValueStore()

        kv.set("from another device", forKey: PrefKey.formatPromptCustom.rawValue)
        kv.set(true, forKey: PrefKey.coachMarkFormatShown.rawValue)

        UbiquitousPrefsMirror.pullFromCloud(from: kv, into: defaults)

        XCTAssertEqual(defaults.string(forKey: PrefKey.formatPromptCustom.rawValue),
                       "from another device",
                       "A mirrored key arriving from iCloud must land in defaults.")
        // NOT `XCTAssertNil`: `Prefs` registers `coachMarkFormatShown` as
        // `false` (Prefs.swift), and the registration domain is process-wide,
        // so `object(forKey:)` resolves to 0 for ANY UserDefaults instance —
        // the key is never absent. The real contract is that the cloud's
        // `true` did not overwrite it.
        XCTAssertFalse(defaults.bool(forKey: PrefKey.coachMarkFormatShown.rawValue),
                       "A non-mirrored key must not be written even if present in KVS.")
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
