# meshpunk-apps

App repository for the [Meshpunk](https://github.com/PhilMo6/meshpunk) T-Deck firmware.
The on-device **App Library** app reads `catalog.toml` from this repo over WiFi and
downloads apps straight onto the device — no reflash, no SD card shuffling.

## How it works

- `catalog.toml` is the single source of truth. The device fetches it, shows the apps
  grouped by category, and downloads each file in an app's `files` array from `apps/<id>/`.
- An app only becomes visible to devices when its entry is merged into `catalog.toml`.
  Files sitting in `apps/` without a catalog entry are invisible — the catalog is the
  curation gate.
- Devices install to the SD card (`/meshpunk/apps/`) or internal flash (`/lua/apps/`),
  into the subfolder named by `category` (or top level when there is no category).

## Repo layout

```
catalog.toml          # master index — metadata + file lists for apps AND themes
apps/
  snake/
    main.lua
  my-app/
    main.lua
    assets.bin
themes/
  meshcore/
    theme.lua         # optionally with bundled wallpaper images beside it
```

## Catalog fields

```toml
[[apps]]
id = "my-app"            # repo folder name under apps/  (lowercase, a-z 0-9 - _)
name = "My App"          # display name AND the install folder name on device
author = "You"
version = "1.0.0"        # bump on every change — devices show "Update" on mismatch
type = "lua"             # "lua" or "elf" (elf = native binary via the ELF loader)
description = "One line shown in the store"
category = "Games"       # optional install subfolder (Games, Tools, ...); omit for top level
files = ["main.lua"]     # every file to download, relative to apps/<id>/
```

## Themes

`[[themes]]` entries in `catalog.toml` use the same fields (no `category`/`type`);
files live under `themes/<id>/` with a `theme.lua` entry point. The device's
Settings > Theme > Get button installs them to `/meshpunk/themes/<id>` (SD, or
internal without a card), where the theme picker discovers them automatically.
A theme returns `{ name, apply(t) }` — see `themes/meshcore/theme.lua` for the
palette + procedural-background toolkit in action.

```toml
[[themes]]
id = "meshcore"
name = "MeshCore"
author = "You"
version = "1.0.0"
description = "One line shown in the theme library"
files = ["theme.lua"]
```

## Contributing an app

1. Fork this repo.
2. Add your app under `apps/<id>/` — it must have a `main.lua` entry point.
3. Add an entry to `catalog.toml` listing **every** file in `files`.
4. Open a PR.

Themes contribute the same way under `themes/<id>/` with a `[[themes]]` entry.

### App guidelines

- Follow the Meshpunk app contract: create your root with `apps.new_root()` exactly once,
  register timers via `apps.add_timer{}`, and exit with `apps.go_home()` — never delete
  your own root. See `apps/hello/main.lua` for the minimal example, or any app in the
  firmware's `data/lua/apps/` for real ones.
- The app receives its install directory as its first argument (`local app_dir = ...`).
  Write save data there (e.g. `app_dir .. "/save.txt"`) so it works from SD and internal.
- Keep file names simple (no spaces); the `id` is lowercase with `-`/`_` only.
  The `name` may contain spaces — it becomes the folder and launcher label.
- Lua apps run in the firmware's Lua sandbox but have access to the full Meshpunk API
  (filesystem, WiFi, LoRa radio) — PRs are reviewed with that in mind.
- ELF apps are native binaries with full hardware access and get extra review scrutiny.

## Trust model

Everything here is curated via PR review. There is no code signing (yet) — devices trust
this repo. Don't point your device's store at repos you don't trust.
