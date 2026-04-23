---
author: open-prompter
title: Open Prompter — The Demo Script
created: 2026-04-23
tags:
  - demo
  - teleprompter
  - everything-markdown
---

# Welcome to Open Prompter

This is the demo script. It uses every markdown construct the parser knows about — **bold**, *italic*, `inline code`, wikilinks, bullets, numbered lists, headings, blockquotes, and callouts — so you can see exactly how each one appears on camera.

If you can read this sentence cleanly, the parser is working.

## Why This Exists

Every teleprompter app on the App Store wants a subscription to unlock **Mirror mode**. Most want your script uploaded to *their* cloud. A few want both.

Open Prompter reads the markdown file you already have, from iCloud Drive or your Obsidian vault, and that's the whole app. Free, open source, MIT licensed.

## Heading Sizes

### This Is a Level-3 Heading

Level-3 headings render slightly larger than body text so they feel like a chapter break without dominating the screen.

#### Level-4 Heading

Level 4 and below fall to the smallest heading size. Use them for sub-points inside a section.

## Lists

Unordered bullets show up with a bullet marker on the left:

- Free forever
- MIT licensed
- No account required
- Works with any markdown file

Ordered lists show the number you wrote:

1. Pick your folder once
2. Tap a script
3. Hit Play
4. Mirror the text if you're using a rig

## Emphasis

**Bold text stays bold** when read aloud — the markers vanish, the weight stays in the rendered output. *Italic also survives.* ***Both together*** nests cleanly. Inline `code spans` drop the backticks so you can pronounce the word naturally on camera.

## Wikilinks

Obsidian-style wikilinks resolve to their display text. [[Clip Sweeper|the storage tool]] becomes "the storage tool," and a bare [[Open Prompter]] becomes "Open Prompter." The brackets never appear on screen.

## Regular Blockquotes

> This is a real quoted line the writer wanted in the script. It's NOT an AI callout, so it stays. The parser strips the leading `>` character and reads it as normal narration.

## Callouts That Aren't AI

> [!note]
> This is a note callout. It appears on camera with the `[!note]` marker stripped but the content preserved. All non-AI callout types (`[!note]`, `[!warning]`, `[!tip]`, `[!quote]`) behave this way.

> [!quote]
> "The right teleprompter is the one that doesn't fight you."

## Numbers and Symbols

Numbers render as-is: $250, 10GbE, 4K. Unicode like “smart quotes,” em-dashes, and ellipses… come through intact. Emoji like 📱 and ✅ render exactly as they do on your Mac.

## A Mixed Paragraph

Here's a long paragraph with varied punctuation, numbers ($250, 10GbE, 4K), parenthetical asides (like this one), and mid-sentence **emphasis** that should flow naturally when read aloud. The goal is to verify that whitespace is collapsed correctly — multiple   spaces become one, and line wraps in the source become a single space in the output.

---

## What the Parser Strips

A handful of things get removed automatically so you don't read them on camera. Everything below this heading demonstrates a stripping rule.

### YAML Frontmatter

The `---`-delimited block at the top of this file. You never hear the word "author" or "tags" during playback.

### AI-Generated Callouts

> [!ai-generated]
> This entire callout block should NOT appear on screen. It's a multi-paragraph AI note.
>
> Second paragraph still inside the callout — also hidden.
>
> Third paragraph, same story. The parser eats the whole block cleanly, not just the first line.

You should read this sentence after the callout just fine.

### Visual Direction Brackets

[B-roll: wide shot of the rig]
[Screen record: the app running on iPhone]
[Text on screen: "mirror is free"]
[insert archival footage of old teleprompters]
[Cut to: close-up of the phone]
[Open with: creator facing camera]

The brackets above vanish. The sentence after them should land on camera intact.

### Footnote Markers and Definitions

You can drop footnotes[^1] in the middle of a line[^sources] and they disappear silently.

The definitions at the bottom of this file[^1] also get stripped out wholesale[^bigger].

[^1]: This definition should never be spoken aloud.
[^sources]: A bigger footnote with multiple sentences. Still dropped.
[^bigger]: A third one with nested **formatting** and a [link](https://example.com). Dropped too.

### Scaffolding Sections

---

### Hook Type: Deinfluencer
### Pillar: Tools & Productivity
### Template: Problem → DIY Solution

---

Those three scaffold lines above don't get spoken. Neither does the section below.

## Footnotes

This entire section is dropped because it starts with the heading "Footnotes."

Any content here is invisible.

## Reference Images

| Shot | Source |
| --- | --- |
| Hero | clipsweeper.com/screenshot.png |
| Demo | openprompter.app/preview.mp4 |

Tables get stripped too. You won't hear pipes.

## Topic Waterfall

This section is also dropped by pattern match on its heading.

---

## Code Blocks and Raw HTML

Code fences get stripped entirely:

```swift
// This code should never reach the prompter.
let x = 1
print(x)
```

You should read this line immediately after the code fence.

<div>Inline HTML blocks are also dropped.</div>

You should not read anything from that div. This sentence survives.

### Task Lists

- [ ] A task that isn't done
- [x] A task that's done
- [ ] Open Prompter v1 shipped

The `[ ]` and `[x]` markers drop; the task descriptions read as normal bullets.

---

## The Close

If you made it this far, the parser is working. Every bracketed cue, every scaffold heading, every footnote marker, every table, every code fence — gone. What's left is the part you actually say on camera.

Now swipe back, pick your own folder, and shoot something.
