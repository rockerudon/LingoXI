# LingoXI

Real-time chat translation addon for Final Fantasy XI using Ashita v4.

LingoXI listens to incoming FFXI chat messages, translates them asynchronously with Google Translate, and displays only the translated result in a clean overlay window. Repeated lines are served from a local cache, so common NPC dialogue and recurring chat messages appear faster after the first translation.

The chat window uses a minimal transparent black style inspired by FancyChat. It keeps the main view focused on translated text only, with no toolbar, title bar, status line, or pending/OK translation markers.

## Features

- Asynchronous translation with short request timeouts.
- Local translation cache stored in `cache.json`.
- Duplicate NPC/story message protection.
- Auto-scroll that follows new messages only when the user is already near the bottom.
- Configurable source and target languages.
- Configurable chat filters by category.
- Custom channel colors by chat mode id.
- Transparent, resizable ImGui chat window with neutral gray controls.

## Commands

Open the configuration window:

```text
/lingoxi config
```

The config window has an `X` button to close it.

## Chat Filters

Open `/lingoxi config` and use `Chat filters` to choose which categories should be translated and displayed:

- NPC / story
- Local / say
- Shout / yell
- Tell
- Party
- Linkshell
- Unity
- Emote / examine
- System / item
- Combat
- Other

Disabled categories are ignored before translation, so they do not enter the translation queue or cache.

## Languages

Common language codes:

`en` English, `pt` Portuguese, `es` Spanish, `fr` French, `de` German, `it` Italian, `ja` Japanese, `zh` Chinese, `ko` Korean, `ru` Russian.

## Files

- `LingoXI.ini`: saved settings, window position, language options, filters, performance options, and channel colors.
- `cache.json`: local translation cache.

---

**Author**: rockmizx

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow.svg?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/rockmizx)
