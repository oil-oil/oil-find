<p align="center">
  <img src="./assets/readme/hero.en.svg" width="100%" alt="Oil Find: Everything, for the Mac. Press ⇧⌘F and results appear as you type.">
</p>

<p align="center">
  <a href="https://github.com/oil-oil/oil-find/releases/latest"><b>Download</b></a>
  &nbsp;·&nbsp;
  <a href="https://find.oiloil.org/en">Website</a>
  &nbsp;·&nbsp;
  <a href="./README.md">中文</a>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./assets/readme/search-en-dark.png">
  <img src="./assets/readme/search-en-light.png" width="100%" alt="The Oil Find search panel: readme is typed, eight results are ranked by relevance with the matching part in blue, and the footer shows the search took 0.2 milliseconds.">
</picture>
</p>

Oil Find is a file search tool for macOS that works like Everything on Windows: it keeps its own in-memory index of every file name on your disk instead of relying on Spotlight. Press ⇧⌘F, a search field appears in the middle of the screen, and results update with every keystroke. When files are created, renamed or deleted, the index follows along in real time.

## Why it's fast

- **File names live in one contiguous block of memory.** Hundreds of thousands of names are stored column by column and scanned front to back, with no per-file objects.
- **Matching runs in C with NEON.** Character comparisons use Apple silicon's vector instructions in batches.
- **Each keystroke narrows the last result.** Typing one more character only searches what already matched.
- **Only changes get updated.** FSEvents reports what changed and the index is updated incrementally. After a restart, Oil Find catches up from where it left off.

Measured on an Apple M5 with 24 GB of memory, using the command-line tool in this repository. Each query ran 20 times; the table shows the median.

| Index scope | Files | Indexing | Resident memory | `readme` | `wd` (pinyin) | `kind:image` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Default | 850K | 3.0 s | 45 MB | 0.6 ms | 0.3 ms | 3.9 ms |
| Whole disk | 7.5M | 27.2 s | 343 MB | 8.1 ms | 3.4 ms | 3.8 ms |

The default scope leaves out dependency folders, app and package internals, Library and system folders. You can turn each of them on in Settings. A single letter matches the most files and is the slowest case: about 11 ms in the default scope and about 58 ms for the whole disk.

## Search syntax

| Type | Meaning |
| --- | --- |
| `wd`, `wendang` | Pinyin initials or full pinyin, finds 文档 |
| `foo bar` | Contains both foo and bar |
| `foo \| bar` | Contains foo or bar |
| `readme !node_modules` | Contains readme, not inside node_modules |
| `*.png` | Wildcards match the whole name |
| `~/Desktop/ png` | Only under the Desktop |
| `ext:pdf;docx` | By extension |
| `kind:image` | By kind: folder, app, doc, image, video, audio, code, archive |
| `file:`, `folder:` | Files only, or folders only |
| `size:>10mb`, `size:1mb..5mb` | By size |
| `dm:today`, `dm:week`, `dm:2026-10-01` | By modification date |
| `regex:^IMG_\d+` | Regular expressions |

You can paste paths straight from a terminal or editor: `file://` URLs, quoted or escaped paths and paths ending in `:line:column` all work. Press ⌘/ in the search field for a syntax reference.

## Keyboard

| Key | Action |
| --- | --- |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> | Open search (configurable in Settings) |
| <kbd>Return</kbd> | Open |
| <kbd>⌘</kbd><kbd>Return</kbd> | Show in Finder |
| <kbd>⌘</kbd><kbd>Y</kbd> | Quick Look |
| <kbd>⌘</kbd><kbd>C</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> | Copy path, copy name |
| <kbd>⌘</kbd><kbd>⌫</kbd> | Move to Trash |
| <kbd>Tab</kbd> / <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> | Switch kind |
| <kbd>⌘</kbd><kbd>/</kbd> | Syntax reference |

You can also drag results into other apps.

## Oil Find Pro

The free version stays free and open source. Pro is a closed-source paid add-on: $9.99 once (¥49 in mainland China), with a 7-day free trial.

- **External drives**: indexed when you plug them in and still searchable after you unplug them. Results show which drive a file is on.
- **Image content**: search the text and objects in screenshots, photos and snapped receipts. Everything is recognized on your Mac and never uploaded.

The builds on Releases and the website include Pro; click Start 7-Day Free Trial in Settings to try it. Building from source gives you the free version. See [find.oiloil.org/en/pro](https://find.oiloil.org/en/pro).

## Install

1. Download `Oil-Find.zip` from [Releases](https://github.com/oil-oil/oil-find/releases/latest), unzip it and drag Oil Find into Applications.
2. The first time you open it, macOS blocks it because it isn't notarized by Apple. Go to System Settings → Privacy & Security and click Open Anyway near the bottom.
3. Press ⇧⌘F and start typing.
4. Optional: grant Full Disk Access to also search mail attachments and other apps' data. Oil Find works fine without it.

When a new version is out, Oil Find tells you; click Update and Restart. You can turn off automatic checks in Settings.

To uninstall, quit Oil Find and delete Oil Find from Applications and `~/Library/Application Support/Oil Find`.

## Build from source

Requires macOS 14 and Swift 5.10 or later (Xcode 15.3 or newer).

```sh
git clone https://github.com/oil-oil/oil-find.git
cd oil-find
swift test
scripts/build-app.sh   # builds build/Oil Find.app
scripts/install.sh     # builds and installs into Applications
```

Building from source gives you the free version, without Pro. Your own builds are ad-hoc signed, so you need to grant Full Disk Access again after each rebuild.

## Privacy

- Oil Find reads file names, sizes and modification dates only, never file contents. With Pro image recognition on, it reads images on your Mac to recognize text and objects, and the results stay on your Mac too.
- The index stays on your Mac in `~/Library/Application Support/Oil Find/`.
- A daily update check fetches one version file and sends no device or usage data. You can turn it off in Settings.
- With Pro, the license is verified online once a day. Only the license key, a device identifier and the device name are sent.

## Current limits

- Apple silicon and macOS 14 or later only.
- Network volumes aren't supported; external drives need Pro.
- File names only, not document contents; Pro also searches the text and objects in images.

## Project layout

| Folder | Contents |
| --- | --- |
| `Sources/COilFind` | C: batched directory reads, name comparison, search scoring |
| `Sources/OilFindCore` | Scanning, indexing, queries, live updates, persistence, app updates |
| `Sources/OilFindApp` | The AppKit app and Settings |
| `Sources/OilFind` | The app's entry point |
| `Sources/oilfind-cli` | Command-line tool for benchmarks and troubleshooting |
| `site` | The website, [find.oiloil.org](https://find.oiloil.org/en) |

See [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) for the index design and [AGENTS.md](./AGENTS.md) for development conventions. Issues and pull requests are welcome.

## License

[MIT](./LICENSE)
