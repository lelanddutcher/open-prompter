# 10-Key Remote Support Changes

## Summary

This change adds Bluetooth 10-key / numeric keypad support to the existing remote-control binding system.

Previously, the app could bind common keyboard keys, arrows, media keys, volume buttons, and pointer clicks, but numeric keypad keys were not represented as `RemoteKey` values. As a result, a Bluetooth 10-key could connect as a keyboard but its numbers and keypad-specific keys could not be learned or mapped to actions such as `Speed up` or `Speed down`.

## What Changed

### New Bindable Keys

`RemoteKey` now supports:

- Top-row digits: `0` through `9`
- Numeric keypad digits: `Keypad 0` through `Keypad 9`
- Numeric keypad operators and controls:
  - `Keypad +`
  - `Keypad -`
  - `Keypad /`
  - `Keypad *`
  - `Keypad .`
  - `Keypad =`
  - `Keypad Enter`
  - `Keypad Num Lock / Clear`

These keys have stable persisted IDs such as `kb.keypad.plus`, `kb.keypad.1`, and `kb.digit.1`.

### Default Bindings

The keypad now has useful defaults without over-assigning every number:

- `Keypad +` -> `Speed up`
- `Keypad -` -> `Speed down`
- `Keypad Enter` -> `Play / pause`

Keypad numbers are intentionally unbound by default, but visible in Settings so users can map them to any remote action.

### GameController Keyboard Mapping

`GameControllerKeyboardSource` now maps `GCKeyCode` keypad values into distinct `RemoteKey` cases.

This is the important path for Bluetooth 10-key devices because many of them emit keypad-specific HID key codes, not ordinary top-row digit codes.

Examples:

- `.keypadPlus` -> `.keypadPlus`
- `.keypadHyphen` -> `.keypadMinus`
- `.keypad1` -> `.keypadDigit("1")`
- `.keypadEnter` -> `.keypadEnter`

Top-row numbers are mapped separately:

- `.one` -> `.digit("1")`
- `.zero` -> `.digit("0")`

This keeps a physical keypad `1` distinct from the main keyboard `1`.

### SwiftUI KeyPress Fallback

`KeyboardEventSource.remoteKey(from:)` now recognizes single-character digits and keypad-style symbols from `KeyPress.characters`.

SwiftUI does not identify whether a digit came from the top row or keypad, so this fallback maps digits to `.digit(...)`. GameController remains the precise path for keypad-specific identity once `GCKeyboard` is attached.

### Settings UI

The Advanced bindings list now shows known configurable keys even when they are currently unbound.

Before this change, only currently-bound keys appeared in the list, which meant newly supported keys like `Keypad 1` could be captured by the wizard but were not easy to browse or assign directly.

The picker also now includes an `Unbound` option so a user can clear a key without needing a separate delete affordance.

## Files Changed

- `OpenPrompter/Features/Remote/RemoteBindingStore.swift`
- `OpenPrompter/Features/Remote/GameControllerKeyboardSource.swift`
- `OpenPrompter/Features/Remote/KeyboardEventSource.swift`
- `OpenPrompter/Features/Settings/RemoteControlSettingsView.swift`
- `OpenPrompterTests/RemoteBindingStoreTests.swift`
- `OpenPrompterTests/GameControllerKeyboardSourceTests.swift`

## Verification

Focused remote tests passed:

```bash
xcodebuild -project OpenPrompter.xcodeproj \
  -scheme OpenPrompter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenPrompterTests/RemoteBindingStoreTests \
  -only-testing:OpenPrompterTests/GameControllerKeyboardSourceTests \
  test
```

Result: 18 tests passed, 0 failures.

Full simulator build passed:

```bash
xcodebuild -project OpenPrompter.xcodeproj \
  -scheme OpenPrompter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Full test suite still has unrelated failures that were not introduced by the keypad change:

- `CameraTests.testStoreDeniedPathReturnsToOff()`
- `FormatPresetStoreTests.testMirrorKeyListIncludesPromptKeysExcludesCoachMark()`

