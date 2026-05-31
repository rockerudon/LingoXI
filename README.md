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

**Author**: rockerudon

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow.svg?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/rockmizx)


## Third-party libraries

LingoXI bundles the following third-party Lua libraries in `libs/`. All are
distributed under the MIT license. Their copyright notices are reproduced here
to satisfy the license terms; the original authors retain all rights.

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
