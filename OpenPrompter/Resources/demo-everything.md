---
author: open-prompter
title: open prompter — the demo script
created: 2026-04-23
tags:
  - demo
  - teleprompter
  - everything-markdown
---

# welcome to open prompter

this is the demo script. it's stuffed with every markdown construct i could think of so you can see what survives, what gets stripped, and what ends up on camera.

if you can read this sentence cleanly, the parser is working.

## why this exists

every teleprompter app on the store wants a subscription to unlock **mirror mode**. most want your script uploaded to *their* cloud. a few want both.

open prompter reads the markdown file you already have, from icloud drive or your obsidian vault, and that's the whole app. free, open source, `MIT` licensed.

---

## what the parser strips

a handful of things get removed automatically so you don't read them on camera. everything on this page below the next heading should disappear from the prompter view.

### 1. yaml frontmatter

the `---`-delimited block at the top of this file. you never hear the word "author" or "tags" during playback.

### 2. ai-generated callouts

> [!ai-generated]
> this entire callout block should NOT appear on screen. it's a multi-paragraph ai note.
>
> second paragraph still inside the callout — also hidden.
>
> third paragraph, same story. the parser should eat the whole block cleanly, not just the first line.

you should read this sentence after the callout just fine.

### 3. visual direction brackets

[B-roll: wide shot of the rig]
[Screen record: the app running on iphone]
[Text on screen: "mirror is free"]
[insert archival footage of old teleprompters]
[Cut to: close-up of the phone]
[Open with: creator facing camera]

the brackets above vanish. the sentence after them should land on camera intact.

### 4. footnote markers and definitions

you can drop footnotes[^1] in the middle of a line[^sources] and they disappear silently.

the definitions at the bottom of this file[^1] also get stripped out wholesale[^bigger].

[^1]: this definition should never be spoken aloud.
[^sources]: a bigger footnote with multiple sentences. still dropped.
[^bigger]: a third one with nested **formatting** and a [link](https://example.com). dropped too.

### 5. scaffolding sections

---

### Hook Type: Deinfluencer
### Pillar: Tools & Productivity
### Template: Problem → DIY Solution

---

those three scaffold lines above don't get spoken. neither does the section below.

## Footnotes

this entire section is dropped because it starts with the heading "Footnotes."

any content here is invisible.

## Reference Images

| shot | source |
| --- | --- |
| hero | clipsweeper.com/screenshot.png |
| demo | openprompter.app/preview.mp4 |

tables get stripped too. you won't hear pipes.

## Topic Waterfall

this section is also dropped by pattern match on its heading.

---

## what the parser keeps

now we're back in regular content. everything below this divider gets read on camera.

### bold and italic

**bold text survives** as plain speech. *italic also survives.* ***even both together.*** the markers (`**`, `*`) disappear; the words stay.

### wikilinks

obsidian-style wikilinks resolve to their display text. [[Clip Sweeper|the storage tool]] becomes "the storage tool," and a bare [[Open Prompter]] becomes "Open Prompter."

### inline code

when i say `NSMetadataQuery` is an ios api, the backticks drop but the word stays so i can pronounce it naturally on camera.

### regular blockquotes

> this is a real quoted line the writer wanted in the script. it's NOT an ai callout, so it stays. the parser strips the leading `>` character and reads it as normal narration.

### links

a [link to openprompter.app](https://openprompter.app) becomes the visible text "link to openprompter.app" — the url is dropped.

### lists

unordered lists become a flowing sentence. so this list:

- free forever
- mit licensed
- no account required

reads as: "free forever. mit licensed. no account required."

ordered lists work the same:

1. pick your folder once
2. tap a script
3. hit play

### line breaks

a line break in markdown  
ends up as a space. you can keep writing naturally.

### horizontal rules and sections

---

the `---` above ends a section. the parser splits on horizontal rules and drops any section that starts with a footnotes / reference / waterfall heading. this section — the one you're reading right now — survives because it doesn't start with one of those.

### callouts that aren't ai-generated

> [!note]
> this is a note callout. it should appear on camera with the `[!note]` marker stripped but the content preserved. callout-type markers (`[!note]`, `[!warning]`, `[!tip]`, etc.) are removed; the text stays.

> [!quote]
> "the right teleprompter is the one that doesn't fight you."

### emphasis inside emphasis

you can nest: **strong text with _nested italic_ inside**, and both markers drop, leaving the words behind.

### code fences

```swift
// code blocks get stripped entirely.
let x = 1
print(x)
```

you should read this line immediately after the code fence. the fence content never gets spoken.

### html blocks and inline html

<div>inline html blocks are dropped.</div>

you should not read the word "inline" or the word "dropped" from that tag. and this sentence survives.

### task lists

- [ ] a task that's not done
- [x] a task that's done
- [ ] open prompter v1 shipped

the `[ ]` and `[x]` markers drop; the task descriptions read as a list.

### emoji and unicode

emoji like 📱 and unicode quotes like "these" and ellipses… render as-is. the parser doesn't strip them.

### long paragraph test

here's a long paragraph with varied punctuation, numbers ($250, 10GbE, 4K), parenthetical asides (like this one), and mid-sentence **emphasis** that should flow naturally when read aloud. the goal is to verify that whitespace is collapsed correctly — multiple   spaces become one,
and line wraps in the source become a single space in the output.

---

## the close

if you made it this far, the parser is working. every bracketed cue, every scaffold heading, every footnote marker, every table, every code fence — gone. what's left is the part you actually say on camera.

now swipe back, pick your own folder, and shoot something.
