//
//  RecordingAspectTests.swift
//  OpenPrompterTests
//
//  Covers the user-configurable recording aspect-ratio picker:
//    - RecordingAspect enum has labels + help-text + Codable round-trip
//    - Default is `.openGate` (3.1 — the full-sensor readout; `.wide` held
//      this slot through 3.0 but 16:9 is a crop off the iPhone 17 family)
//    - openGate leads `surfacedCases` so the picker's first row is also the
//      fresh-install selection
//    - Prefs.register() with no prior keys → recordingAspect == "openGate"
//    - migrateRecordingAspectToOpenGate(...) pins existing users to
//      "openGate" without touching brand-new installs OR users who've
//      already explicitly set the aspect themselves. As of 3.1 it writes the
//      SAME value the registration default supplies, so the two paths agree —
//      the migration is retained because it PERSISTS the value.
//    - migrateVerticalAspectToWideShape(...) collapses a persisted legacy
//      "ratio9x16" onto the merged 16:9 shape "ratio16x9" (V3 §07)
//    - canonicalShape collapses the .legacyVertical9x16 alias onto .wide
//
//  Test scaffolding mirrors MirrorAxesTests: snapshot+restore the touched
//  UserDefaults keys on standard, plus an isolated UUID-named suite for
//  the migration tests so they don't pollute (or read) the host process's
//  registration domain.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class RecordingAspectTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Standard-defaults keys this suite mutates for the new-user default
    /// test. Snapshotted at setUp and restored at tearDown so other tests
    /// in the process see pristine state.
    private let aspectKeys: [String] = [
        PrefKey.recordingAspect.rawValue,
        PrefKey.recordingQuality.rawValue,
        PrefKey.recordingFramerate.rawValue,
        PrefKey.cameraStyle.rawValue,
        PrefKey.coachMarkRecordingAspectShown.rawValue
    ]

    private var savedValues: [String: Any?] = [:]

    /// Suite domain names created by makeIsolatedStore so tearDown can wipe
    /// them off disk and not leave .plist droppings in the simulator.
    private var createdSuites: [String] = []

    override func setUp() {
        super.setUp()
        let store = UserDefaults.standard
        savedValues.removeAll(keepingCapacity: true)
        for key in aspectKeys {
            savedValues[key] = store.object(forKey: key)
            store.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let store = UserDefaults.standard
        for key in aspectKeys {
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
        let suiteName = "test.recording-aspect.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        let store = UserDefaults(suiteName: suiteName)!
        createdSuites.append(suiteName)
        return (store, suiteName)
    }

    // MARK: - Enum surface

    func testAllCasesHaveDisplayName() {
        for aspect in RecordingAspect.allCases {
            XCTAssertFalse(aspect.displayName.isEmpty,
                           "RecordingAspect.\(aspect.rawValue).displayName must not be empty.")
            XCTAssertFalse(aspect.helpText.isEmpty,
                           "RecordingAspect.\(aspect.rawValue).helpText must not be empty.")
        }
    }

    func testCodableRoundTrip() throws {
        for aspect in RecordingAspect.allCases {
            let data = try JSONEncoder().encode(aspect)
            let decoded = try JSONDecoder().decode(RecordingAspect.self, from: data)
            XCTAssertEqual(decoded, aspect,
                           "RecordingAspect.\(aspect.rawValue) must round-trip cleanly.")
        }
    }

    /// 3.1: the new-user default is the full-sensor readout, NOT `.wide`.
    /// 16:9 is a crop on every front sensor that isn't natively 16:9, which
    /// made it a surprising first-record aspect off the iPhone 17 family.
    /// Open gate has no `requiresIOS26` constraint, so there is nothing to
    /// fall back FROM. Intentionally brittle — flipping the default back
    /// should fail here.
    func testDefaultIsOpenGate() {
        XCTAssertEqual(RecordingAspect.default, .openGate,
                       "New-user default must be the full-sensor open-gate shape (3.1).")
        XCTAssertEqual(RecordingAspect.default.rawValue, "openGate",
                       "New-user default raw value must be \"openGate\".")
        XCTAssertFalse(RecordingAspect.default.requiresIOS26,
                       "The default shape must be honorable on every OS we ship to.")
    }

    /// The registration domain must agree with `RecordingAspect.default` —
    /// they are two independent declarations of the same fact and drifting
    /// apart is exactly the bug class this guards.
    func testRegistrationDefaultMatchesEnumDefault() {
        XCTAssertEqual(PrefKey.recordingAspect.defaultValue as? String,
                       RecordingAspect.default.rawValue,
                       "PrefKey.recordingAspect registration default must equal RecordingAspect.default.")
    }

    /// The downgrade-safety alias must collapse onto `.wide` via
    /// `canonicalShape`, and a persisted legacy raw must still decode.
    func testLegacyVerticalAliasCanonicalizesToWide() {
        XCTAssertEqual(RecordingAspect(rawValue: "ratio9x16"), .legacyVertical9x16,
                       "Persisted legacy \"ratio9x16\" must still decode.")
        XCTAssertEqual(RecordingAspect.legacyVertical9x16.canonicalShape, .wide,
                       "The legacy 9:16 alias must canonicalize to .wide.")
        // Every surfaced shape is its own canonical form.
        for shape in RecordingAspect.surfacedCases {
            XCTAssertEqual(shape.canonicalShape, shape)
        }
    }

    /// The surfaced picker set is exactly the four shapes — never the alias.
    /// Order is load-bearing: open gate FIRST (3.1) so the picker's leading
    /// row is also the fresh-install selection.
    func testSurfacedCasesExcludeAlias() {
        XCTAssertEqual(RecordingAspect.surfacedCases, [.openGate, .wide, .classic, .square])
        XCTAssertFalse(RecordingAspect.surfacedCases.contains(.legacyVertical9x16))
    }

    /// The picker's first row must be the default, so a fresh install opens
    /// the menu on the top entry rather than scrolled to the bottom.
    func testDefaultLeadsThePicker() {
        XCTAssertEqual(RecordingAspect.surfacedCases.first, RecordingAspect.default,
                       "Open gate must lead the picker — it is the default (3.1).")
    }

    // MARK: - Prefs default + migration

    /// Brand-new install: no prior recording-related keys are written.
    /// `Prefs.register()` should land on `"openGate"` (the 3.1 registration-
    /// domain default). Note this test exercises the global UserDefaults —
    /// we cleared it in setUp so the registration default applies.
    ///
    /// setUp also clears `recordingQuality` / `recordingFramerate` /
    /// `cameraStyle`, so `migrateRecordingAspectToOpenGate` sees a pristine
    /// install and short-circuits: the value under test comes from the
    /// registration domain, not the migration.
    func testNewUserDefaultIsOpenGate() {
        // Sanity — setUp removed any persisted aspect value from the
        // standard defaults. Registering re-installs the registration-
        // domain default.
        Prefs.register()
        XCTAssertEqual(Prefs.recordingAspect, "openGate",
                       "Fresh install should start at \"openGate\".")
        XCTAssertEqual(RecordingAspect(rawValue: Prefs.recordingAspect)?.canonicalShape,
                       .openGate,
                       "The persisted fresh-install value must decode to .openGate.")
    }

    /// The getter's hard-coded fallback (used when nothing is stored and
    /// nothing is registered) must agree with the registration default —
    /// otherwise a read that beats `Prefs.register()` returns a different
    /// shape than one that follows it.
    func testGetterFallbackMatchesRegistrationDefault() {
        let store = UserDefaults.standard
        store.removeObject(forKey: PrefKey.recordingAspect.rawValue)
        // No register() call here: exercise the `?? "openGate"` branch. The
        // host process may have registered a value already, so accept either
        // the fallback or the (identical) registration default.
        XCTAssertEqual(Prefs.recordingAspect, "openGate",
                       "Getter fallback must be \"openGate\", matching the registration default.")
    }

    /// V3 §07: a persisted legacy "ratio9x16" is rewritten to "ratio16x9"
    /// (the merged .wide shape) by the one-shot migration.
    func testLegacyVerticalMigratesToWideShape() {
        let (store, domain) = makeIsolatedStore()
        store.set("ratio9x16", forKey: PrefKey.recordingAspect.rawValue)

        Prefs.migrateVerticalAspectToWideShape(in: store, domain: domain)

        XCTAssertEqual(store.string(forKey: PrefKey.recordingAspect.rawValue),
                       "ratio16x9",
                       "Legacy \"ratio9x16\" must migrate to \"ratio16x9\" (.wide).")
    }

    /// The vertical-shape migration only rewrites the exact legacy string —
    /// other values (and a fresh install with no value) are untouched, and it
    /// is idempotent.
    func testVerticalMigrationLeavesOtherValuesUntouched() {
        let (store, domain) = makeIsolatedStore()
        for value in ["ratio16x9", "ratio4x3", "ratio1x1", "openGate"] {
            store.set(value, forKey: PrefKey.recordingAspect.rawValue)
            Prefs.migrateVerticalAspectToWideShape(in: store, domain: domain)
            XCTAssertEqual(store.string(forKey: PrefKey.recordingAspect.rawValue), value,
                           "\(value) must be left untouched by the vertical migration.")
        }
        // No-op for a pristine install (no aspect key).
        let (fresh, freshDomain) = makeIsolatedStore()
        Prefs.migrateVerticalAspectToWideShape(in: fresh, domain: freshDomain)
        let persistent = fresh.persistentDomain(forName: freshDomain) ?? [:]
        XCTAssertNil(persistent[PrefKey.recordingAspect.rawValue],
                     "Vertical migration must not write the aspect key for a fresh install.")
    }

    /// Existing user: any of `recordingQuality`, `recordingFramerate`, or
    /// `cameraStyle` is set. The migration should flip the aspect to
    /// "openGate" so the introduction of the picker doesn't silently
    /// reshape their next recording.
    func testExistingUserMigratesToOpenGate() {
        let (store, domain) = makeIsolatedStore()
        // Simulate an existing user who's recorded before — the quality
        // key was written explicitly the moment they touched Settings.
        store.set("high", forKey: PrefKey.recordingQuality.rawValue)

        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)

        XCTAssertEqual(store.string(forKey: PrefKey.recordingAspect.rawValue),
                       "openGate",
                       "Existing users must be migrated to \"openGate\".")
    }

    /// Migration must not stomp a user-set aspect on subsequent runs.
    /// Once the user has chosen anything (even via the picker introducing
    /// the new default), re-running migration should be a no-op.
    func testMigrationIdempotent() {
        let (store, domain) = makeIsolatedStore()
        store.set("high", forKey: PrefKey.recordingQuality.rawValue)
        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)
        // First migration set "openGate". Now simulate the user changing
        // the picker to "ratio16x9" via Settings.
        store.set("ratio16x9", forKey: PrefKey.recordingAspect.rawValue)

        // A second migration call must not stomp the user's choice.
        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)

        XCTAssertEqual(store.string(forKey: PrefKey.recordingAspect.rawValue),
                       "ratio16x9",
                       "Re-running migration must not overwrite a user-set aspect.")
    }

    /// If the user explicitly set a recordingAspect (e.g. via a future
    /// build-time default change, or sideloaded a plist with one), the
    /// migration must respect their choice on the very first run.
    func testMigrationDoesNotOverrideExplicitChoice() {
        let (store, domain) = makeIsolatedStore()
        store.set("high", forKey: PrefKey.recordingQuality.rawValue)
        // User has already declared their aspect — could be a future
        // default change or a sideloaded plist.
        store.set("ratio4x3", forKey: PrefKey.recordingAspect.rawValue)

        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)

        XCTAssertEqual(store.string(forKey: PrefKey.recordingAspect.rawValue),
                       "ratio4x3",
                       "Migration must not override an already-set aspect.")
    }

    /// Pristine new install: no recording-related keys, no aspect key.
    /// Migration must NOT pre-write the aspect — the registration-domain
    /// default ("openGate") does the work for fresh installs. Keeping the
    /// migration write out of the fresh-install path is what lets a future
    /// default change reach new users while leaving existing users pinned.
    func testMigrationNoOpsForNewInstall() {
        let (store, domain) = makeIsolatedStore()
        // Pristine — no prior recording feature touched.

        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)

        let persistent = store.persistentDomain(forName: domain) ?? [:]
        XCTAssertNil(persistent[PrefKey.recordingAspect.rawValue],
                     "New-install migration must not write the aspect key — registration default handles it.")
    }

    /// 3.1 convergence check: the existing-user migration and the new-user
    /// registration default now produce the SAME shape. This is the guard
    /// against the migration and the default drifting apart again — and it
    /// documents that the two are not in conflict (the migration short-
    /// circuits on any existing value, so it can never double-apply).
    func testMigrationAndRegistrationDefaultAgree() {
        let (store, domain) = makeIsolatedStore()
        store.set("high", forKey: PrefKey.recordingQuality.rawValue)

        // Existing-user path.
        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)
        let migrated = store.string(forKey: PrefKey.recordingAspect.rawValue)

        XCTAssertEqual(migrated, PrefKey.recordingAspect.defaultValue as? String,
                       "Existing-user migration must land on the same shape as a fresh install (3.1).")
        XCTAssertEqual(migrated, RecordingAspect.default.rawValue)

        // Re-running is a no-op — the guard sees a value and short-circuits,
        // so there is no double-apply hazard now that the values match.
        Prefs.migrateRecordingAspectToOpenGate(in: store, domain: domain)
        XCTAssertEqual(store.string(forKey: PrefKey.recordingAspect.rawValue), migrated,
                       "Migration must remain idempotent.")
    }
}
