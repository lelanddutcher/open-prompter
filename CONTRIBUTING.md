# contributing

prs are welcome. keep them small and focused.

## setup

1. clone the repo
2. install xcodegen: `brew install xcodegen`
3. generate the xcode project: `xcodegen generate`
4. open `OpenPrompter.xcodeproj` in xcode 16+
5. set your team in signing, run on a device or simulator

## where to start

issues tagged `good-first-issue` are scoped to land in an afternoon. pick one, comment on it so we don't both do the same thing, open a draft pr early if you want feedback.

## style

- tests required for parsing and autoscroll changes
- one feature per pr; refactors get their own pr
- ui changes need a screenshot or short recording in the pr body
- match existing file-organization: App / Features / Parsing / Persistence / Sync / UI

## what not to do

- don't add analytics, telemetry, or network calls without a design discussion
- don't add third-party dependencies without one either
- don't reformat files you didn't touch

## questions

open them in a pr or file an issue. no dms — everything in the open.
