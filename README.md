# QuotaPet · 额度桌宠

A small native macOS menu bar and floating desktop widget for Codex subscription quota. 一个为当时 ChatGPT Plus 使用方式制作的原生 macOS 额度桌宠。

**Historical archive — retired on 2026-10-19.** This project completed its job on its author's Mac and is published for learning and reuse. It is not actively maintained. The original quota logic requires both primary and secondary windows and labels them as 5-hour and weekly; it does not adapt to accounts that expose a single weekly window, including some Pro accounts. These assumptions are preserved rather than redesigned. Use a maintained tool such as [CodexBar](https://github.com/steipete/CodexBar) for daily monitoring.

## Features / 功能

- Menu bar remaining percentages for the original 5-hour and weekly quota windows.
- A draggable floating panel with two colored quota rings.
- Automatic refresh every two minutes; double-click the panel to refresh immediately.
- Reset times and the available reset-credit count reported by the local Codex app-server.
- Uses the existing local Codex sign-in through `codex app-server`; does not directly read credential files or conversation transcripts.

## Requirements / 环境要求

- macOS 13 or later.
- A signed-in Codex executable at one of the paths listed in `src/QuotaPet.m` (the historical ChatGPT/Codex application bundle paths, `/usr/local/bin/codex`, or `/opt/homebrew/bin/codex`). Modern application layouts may differ.
- To build: Apple's Command Line Tools or Xcode.

## Build / 构建

```sh
./build.sh
open build/QuotaPet.app
```

The build script compiles the preserved Objective-C implementation and ad-hoc signs the bundle locally. It changes no installed application and requires no third-party packages. To select a specific installed SDK:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./build.sh
```

The Objective-C implementation was build-checked with the macOS 26.5 SDK when this archive was prepared. This is a build check, not a claim that its old quota parser still works with all current plans. `src/QuotaPet.swift` is a separate historical Swift implementation preserved verbatim; the default build uses `QuotaPet.m`.

## Original artifacts / 原始资料

- `src/`: both original source files and `Info.plist`, unchanged.
- `docs/original-readme.md`: original project README.
- `docs/usage.zh-CN.md`: original Chinese usage guide.
- `reference/codex-app-schema/`: generated Codex app-server protocol snapshot used during development; not needed to build the app. See `reference/README.md` for attribution.
- `docs/original-files.sha256.json`: original-file checksums and archive mapping.
- [Release v0.1.0-archive](https://github.com/gingerjxl03/quotapet/releases/tag/v0.1.0-archive): original packaged ZIP, a clean ZIP of the final local app bundle, and a complete source archive.

The original binary artifacts are Apple Silicon (`arm64`), ad-hoc signed and not Apple-notarized. They are historical artifacts; building from source is preferable if adapting the project.

Personal preferences, crash reports, Finder metadata outside the original ZIP, empty compiler caches, account credentials, and conversation history are not included.

## Usage / 使用

See [中文使用说明](docs/usage.zh-CN.md). The floating panel can be dragged beside a desktop pet, but QuotaPet is an independent app. It is not affiliated with OpenAI.

## License

Original QuotaPet code and documentation: [MIT](LICENSE), copyright 2026 gingerjxl03. The generated Codex protocol reference is attributed to OpenAI Codex and accompanied by its Apache-2.0 license. No OpenAI application or Codex executable is redistributed.
