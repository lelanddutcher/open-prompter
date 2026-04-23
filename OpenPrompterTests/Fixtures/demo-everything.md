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

### 1. yaml frontmatter

the `---`-delimited block at the top of this file.

### 2. ai-generated callouts

> [!ai-generated]
> this entire callout block should NOT appear on screen. it's a multi-paragraph ai note.
>
> second paragraph still inside the callout — also hidden.
>
> third paragraph, same story.

you should read this sentence after the callout just fine.

### 3. visual direction brackets

[B-roll: wide shot of the rig]
[Screen record: the app running on iphone]
[Text on screen: "mirror is free"]
[insert archival footage]
[Cut to: close-up of the phone]

the brackets above vanish.

### 4. footnote markers

you can drop footnotes[^1] in the middle of a line[^sources] and they disappear silently.

[^1]: this definition should never be spoken aloud.
[^sources]: a bigger footnote with multiple sentences. still dropped.

### 5. scaffolding sections

---

### Hook Type: Deinfluencer
### Pillar: Tools & Productivity
### Template: Problem → DIY Solution

---

those three scaffold lines above don't get spoken.

## Footnotes

this entire section is dropped because it starts with "Footnotes."

## Reference Images

| shot | source |
| --- | --- |
| hero | clipsweeper.com/screenshot.png |

## Topic Waterfall

this section is also dropped by pattern match on its heading.

---

## what the parser keeps

### bold and italic

**bold text survives** as plain speech. *italic also survives.* ***even both together.***

### wikilinks

[[Clip Sweeper|the storage tool]] becomes "the storage tool," and a bare [[Open Prompter]] becomes "Open Prompter."

### inline code

when i say `NSMetadataQuery` is an ios api, the backticks drop.

### regular blockquotes

> this is a real quoted line the writer wanted in the script. it's NOT an ai callout, so it stays.

### links

a [link to openprompter.app](https://openprompter.app) becomes the visible text.

### lists

- free forever
- mit licensed
- no account required

ordered:

1. pick your folder once
2. tap a script
3. hit play

### horizontal rules and sections

---

the `---` above ends a section.

### callouts that aren't ai-generated

> [!note]
> this should appear with the marker stripped.

> [!quote]
> "the right teleprompter is the one that doesn't fight you."

### code fences

```swift
let x = 1
print(x)
```

you should read this line immediately after the code fence.

### html blocks

<div>inline html blocks are dropped.</div>

you should not read that tag.

### task lists

- [ ] a task that's not done
- [x] a task that's done

### emoji and unicode

emoji like 📱 and unicode quotes like "these" and ellipses… render as-is.

---

## the close

if you made it this far, the parser is working.
