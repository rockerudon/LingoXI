# LingoXI

Real-time chat translation addon for Final Fantasy XI using Ashita v4.

LingoXI translates incoming chat asynchronously, keeps a local cache for repeated lines, and can show the translated text in a clean ImGui overlay or print it back into the in-game chat. It is built to stay local to your client: it reads chat, requests translations, and optionally adds translated lines to your own chat log.

## Features

- Asynchronous translation through Google Translate.
- Local translation cache stored in `cache.json`.
- Compact transparent overlay window for translated chat.
- Optional translated lines in the in-game chat.
- Optional `[LingoXI]` prefix for printed in-game translations.
- Client color support for both the overlay and printed chat.
- Custom colors per chat category when client colors are disabled.
- Configurable source and target languages.
- Auto-detect source language option.
- Configurable chat filters by category.
- Auto-translate terms are protected so entries like `[Auto Refresh]` are not translated.
- `/lingo` and `/lingoxi` command aliases.

## Install

Copy the `LingoXI` folder to:

```text
Ashita/addons/LingoXI
```

Then load it in game:

```text
/addon load LingoXI
```

## Commands

```text
/lingo config
/lingoxi config
```

Open the configuration window.

```text
/lingo hide
/lingoxi hide
```

Hide the main translation overlay.

```text
/lingo show
/lingoxi show
```

Show the main translation overlay again.

## Configuration

Open `/lingo config` to configure:

- Overlay visibility and transparency.
- In-game translated chat output.
- In-game chat prefix.
- Source and target languages.
- Auto-detect source language.
- Client colors or custom category colors.
- Chat category filters.

## Chat Filters

LingoXI can filter these categories before sending anything to translation:

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

Disabled categories are ignored before translation, so they do not enter the queue or cache.

## Languages

Common language codes:

```text
en English
pt Portuguese
es Spanish
fr French
de German
it Italian
ja Japanese
zh Chinese
ko Korean
ru Russian
```

## Files

- `LingoXI.lua`: addon entry point.
- `libs/`: bundled Lua networking and async libraries.
- `LingoXI.ini`: saved settings, window position, filters, language options, and colors.
- `cache.json`: local translation cache created at runtime.

`LingoXI.ini` and `cache.json` are created in the addon folder when needed.

## Notes

- LingoXI does not send gameplay packets or automate gameplay actions.
- New translations require internet access.
- Cached translations can be shown without requesting the same line again.
- Printed in-game translations are local chat lines added by the client.

---

**Author**: rockerudon

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow.svg?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/rockmizx)

## Third-party libraries

LingoXI bundles the following third-party Lua libraries in `libs/`. All are distributed under the MIT license. Their copyright notices are reproduced here to satisfy the license terms; the original authors retain all rights.

- LuaSocket (`socket/`, `socket/url.lua`) - Copyright (c) Diego Nehab. MIT license.
- Copas (`copas.lua`) - Copyright (c) Kepler Project / Copas contributors. MIT license.
- coxpcall (`coxpcall.lua`) - Copyright (c) Kepler Project. MIT license.
- lua-binaryheap (`binaryheap.lua`) - Copyright (c) Thijs Schreijer. MIT license.
- lua-timerwheel (`timerwheel.lua`) - Copyright (c) Thijs Schreijer. MIT license.

Each library is licensed under the MIT license:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
