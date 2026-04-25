//
//  MirrorAxesTests.swift
//  OpenPrompterTests
//
//  Covers the second-axis mirror feature (Roadmap V2 §6):
//  - PrefKey + Prefs accessors for hMirrorDefault / vMirrorDefault
//  - Migration from the legacy single-axis `pref.mirrorDefault` key
//  - PrompterViewModel toggling and seeding from prefs
//

import XCTest
@testable import OpenPrompter

@MainActor
final class MirrorAxesTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Standard-defaults keys this suite mutates for the view-model seeding
    /// tests. Snapshotted at setUp and restored at tearDown so other tests
    /// in the process see pristine state.
    private let mirrorKeys: [String] = [
        PrefKey.mirrorDefault.rawValue,
        PrefKey.hMirrorDefault.rawValue,
        PrefKey.vMirrorDefault.rawValue
    ]

    /// Snapshot of the values in standard defaults at test start, restored
    /// on tearDown.
    private var savedValues: [String: Any?] = [:]

    /// Suite domain names created by makeIsolatedStore so tearDown can wipe
    /// them off disk and not leave .plist droppings in the simulator.
    private var createdSuites: [String] = []

    override func setUp() {
        super.setUp()
        let store = UserDefaults.standard
        savedValues.removeAll(keepingCapacity: true)
        for key in mirrorKeys {
            savedValues[key] = store.object(forKey: key)
            store.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let store = UserDefaults.standard
        for key in mirrorKeys {
            if case let .some(value?) = savedValues[key] {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        savedValues.removeAll()
        for name in createdSuites {
            UserDefaults().removePersistentDomain(forName: name)
        }
        createdSuites.removeAll()
        super.tearDown()
    }

    /// Returns a freshly-named UserDefaults backed by a UUID suite name,
    /// along with that name. The suite is empty on creation: each test
    /// starts with no values written for any key. Reads via
    /// `persistentDomain(forName:)` skip the process-wide registration
    /// domain, so framework-default fallbacks injected by the host app
    /// don't leak into the test.
    private func makeIsolatedStore() -> (store: UserDefaults, domain: String) {
        let suiteName = "test.mirror.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        let store = UserDefaults(suiteName: suiteName)!
        createdSuites.append(suiteName)
        return (store, suiteName)
    }

    /// Synthetic ScriptFile sufficient to construct a PrompterViewModel for
    /// tests that exercise toggle / seeding logic without touching disk.
    private func makeFile() -> ScriptFile {
        let url = URL(fileURLWithPath: "/tmp/test-mirror.md")
        return ScriptFile(id: url, name: "test-mirror.md", mtime: .now, downloadState: .current)
    }

    // MARK: - Migration

    func testMigrationCopiesLegacyTrueValueToHorizontal() {
        let (store, domain) = makeIsolatedStore()
        // Simulate an existing v1 user who had mirror enabled.
        store.set(true, forKey: PrefKey.mirrorDefault.rawValue)

        Prefs.migrateLegacyMirrorKey(in: store, domain: domain)

        XCTAssertTrue(store.bool(forKey: PrefKey.hMirrorDefault.rawValue),
                      "Legacy mirrorDefault=true must migrate to hMirrorDefault=true.")
        // Legacy key intentionally left in place for downgrade safety.
        let persistent = store.persistentDomain(forName: domain) ?? [:]
        XCTAssertNotNil(persistent[PrefKey.hMirrorDefault.rawValue],
                        "Migration must mark hMirrorDefault as explicitly set.")
        XCTAssertNotNil(persistent[PrefKey.mirrorDefault.rawValue],
                        "Legacy key should be preserved post-migration.")
    }

    func testMigrationCopiesLegacyFalseValueToHorizontal() {
        let (store, domain) = makeIsolatedStore()
        store.set(false, forKey: PrefKey.mirrorDefault.rawValue)

        Prefs.migrateLegacyMirrorKey(in: store, domain: domain)

        XCTAssertFalse(store.bool(forKey: PrefKey.hMirrorDefault.rawValue),
                       "Legacy mirrorDefault=false must migrate to hMirrorDefault=false.")
        let persistent = store.persistentDomain(forName: domain) ?? [:]
        XCTAssertNotNil(persistent[PrefKey.hMirrorDefault.rawValue],
                        "Even a false legacy value should be migrated explicitly.")
    }

    func testMigrationLeavesVerticalUntouched() {
        let (store, domain) = makeIsolatedStore()
        store.set(true, forKey: PrefKey.mirrorDefault.rawValue)

        Prefs.migrateLegacyMirrorKey(in: store, domain: domain)

        let persistent = store.persistentDomain(forName: domain) ?? [:]
        XCTAssertNil(persistent[PrefKey.vMirrorDefault.rawValue],
                     "Vertical mirror should remain unset by the legacy migration.")
    }

    func testMigrationIsIdempotent() {
        let (store, domain) = makeIsolatedStore()
        store.set(true, forKey: PrefKey.mirrorDefault.rawValue)
        Prefs.migrateLegacyMirrorKey(in: store, domain: domain)
        // Simulate the user later turning the new horizontal key OFF.
        store.set(false, forKey: PrefKey.hMirrorDefault.rawValue)

        // A second migration call must not stomp the user's new choice.
        Prefs.migrateLegacyMirrorKey(in: store, domain: domain)

        XCTAssertFalse(store.bool(forKey: PrefKey.hMirrorDefault.rawValue),
                       "Re-running migration must not overwrite a user-set hMirrorDefault.")
    }

    func testMigrationNoOpsWhenLegacyUnset() {
        let (store, domain) = makeIsolatedStore()
        // No legacy value written — pristine new install.
        Prefs.migrateLegacyMirrorKey(in: store, domain: domain)

        let persistent = store.persistentDomain(forName: domain) ?? [:]
        XCTAssertNil(persistent[PrefKey.hMirrorDefault.rawValue],
                     "Without a legacy value, hMirrorDefault should remain unset.")
        XCTAssertNil(persistent[PrefKey.vMirrorDefault.rawValue])
    }

    // MARK: - View model toggling

    func testToggleHorizontalFlipsOnlyHorizontal() {
        let vm = PrompterViewModel(file: makeFile())
        let startH = vm.mirroredHorizontal
        let startV = vm.mirroredVertical

        vm.toggleMirror()

        XCTAssertEqual(vm.mirroredHorizontal, !startH,
                       "toggleMirror() must invert the horizontal axis.")
        XCTAssertEqual(vm.mirroredVertical, startV,
                       "toggleMirror() must not touch the vertical axis.")
    }

    func testToggleVerticalFlipsOnlyVertical() {
        let vm = PrompterViewModel(file: makeFile())
        let startH = vm.mirroredHorizontal
        let startV = vm.mirroredVertical

        vm.toggleMirrorVertical()

        XCTAssertEqual(vm.mirroredVertical, !startV,
                       "toggleMirrorVertical() must invert the vertical axis.")
        XCTAssertEqual(vm.mirroredHorizontal, startH,
                       "toggleMirrorVertical() must not touch the horizontal axis.")
    }

    func testBothAxesIndependent() {
        let vm = PrompterViewModel(file: makeFile())
        // Force both off.
        if vm.mirroredHorizontal { vm.toggleMirror() }
        if vm.mirroredVertical { vm.toggleMirrorVertical() }

        // Both on.
        vm.toggleMirror()
        vm.toggleMirrorVertical()
        XCTAssertTrue(vm.mirroredHorizontal)
        XCTAssertTrue(vm.mirroredVertical)

        // Horizontal off, vertical still on.
        vm.toggleMirror()
        XCTAssertFalse(vm.mirroredHorizontal)
        XCTAssertTrue(vm.mirroredVertical)

        // Both off.
        vm.toggleMirrorVertical()
        XCTAssertFalse(vm.mirroredHorizontal)
        XCTAssertFalse(vm.mirroredVertical)
    }

    // MARK: - Seeding from prefs

    func testViewModelInitSeedsFromPrefs() {
        let std = UserDefaults.standard
        std.set(true, forKey: PrefKey.hMirrorDefault.rawValue)
        std.set(true, forKey: PrefKey.vMirrorDefault.rawValue)

        let vm = PrompterViewModel(file: makeFile())
        XCTAssertTrue(vm.mirroredHorizontal,
                      "VM must seed horizontal from Prefs.hMirrorDefault.")
        XCTAssertTrue(vm.mirroredVertical,
                      "VM must seed vertical from Prefs.vMirrorDefault.")

        std.set(false, forKey: PrefKey.hMirrorDefault.rawValue)
        std.set(false, forKey: PrefKey.vMirrorDefault.rawValue)
        let vm2 = PrompterViewModel(file: makeFile())
        XCTAssertFalse(vm2.mirroredHorizontal)
        XCTAssertFalse(vm2.mirroredVertical)
    }

    // MARK: - Defaults

    func testDefaultValuesAreBothOff() {
        XCTAssertEqual(PrefKey.hMirrorDefault.defaultValue as? Bool, false,
                       "Per spec, horizontal mirror defaults off.")
        XCTAssertEqual(PrefKey.vMirrorDefault.defaultValue as? Bool, false,
                       "Per spec, vertical mirror defaults off.")
    }
}
