# Launcher

A small, native Spotlight replacement for macOS. One Swift file, no dependencies.

## Features

- **⌘Space** to open or close the launcher
- **App search** across `/Applications`, `/System/Applications`, `~/Applications` and Finder, matching English names, localized names, pinyin and initials (e.g. `wx` → 微信, `vsc` → Visual Studio Code)
- **Keep Awake**: toggles `caffeinate -dims` (type `awake`). caffeinate exits when Launcher exits.
- **Launch at Login** toggle
- **Menu bar icon**: magnifying glass normally, coffee cup while Keep Awake is on

### Keys

| Key | Action |
| --- | --- |
| ⌘Space | Open / close |
| ↑ / ↓ | Move selection |
| Return | Run selected item |
| Esc | Clear the query, then close |

## Install

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh install
```

This builds `build/Launcher.app`, copies it to `/Applications` and launches it. Run `./build.sh` alone to build without installing.

Before ⌘Space works, turn off Spotlight's shortcut: **System Settings → Keyboard → Keyboard Shortcuts → Spotlight**, uncheck **Show Spotlight search**.

## Layout

```
Sources/main.swift   the whole app
Info.plist           bundle metadata (LSUIElement: no Dock icon)
build.sh             build, ad-hoc sign, optionally install
```
