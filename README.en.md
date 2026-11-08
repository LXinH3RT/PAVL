<img src="docs/images/logo.png" width="96" alt="PAVL">

# PAVL · Play All Videos in Lan

English | [简体中文](README.md)

Watch your own video library around the house: a server runs on one Windows machine and shares your
video folders; clients on the same network connect and play. The server never decodes or transcodes
anything — it just serves files over HTTP Range — and all decoding happens on the client. That is why
MKV, HEVC, AV1, ASS subtitles and PGS image subtitles all play as they are.

![Connect to a server](docs/images/client-connect.png)

## What it solves

The usual setup at home is "one machine stores the videos, other devices watch them". Every common
option has its own friction: DLNA stalls when you seek because something has to transcode, SMB support
is uneven on mobile, and cloud-drive style players ignore embedded subtitles.

PAVL splits the problem in two:

* **The server only serves bytes** — it indexes the folders, answers HTTP Range requests, and stores
  playback progress. It never touches the video content, so it fits in a single small executable and
  stays cheap while idle.
* **The client only decodes** — it bundles libmpv, so MKV, HEVC, AV1, rich ASS subtitles and PGS image
  subtitles play directly. The server does no remuxing of any kind.

With that split, the only remaining bottleneck is the network itself: on a gigabit LAN seeking responds
in milliseconds and the server's CPU stays nearly idle.

What it does not do: no transcoding, no download cache, no metadata scraping, no internet exposure.
Which formats play is a property of the client, not of the server.

## Features

| | |
|-|-|
| **Discovery** | UDP broadcast discovery on the LAN; remembers the last address and connects directly first; manual IP entry as a fallback |
| **Pairing** | One-time 6-digit PIN, exchanged for a 32-byte token; later connections are automatic. Paired devices can be reviewed and revoked from the server |
| **Browsing** | Drill down folder by folder with item counts and file sizes; breadcrumbs jump back to any level; folders with no media are hidden |
| **Sorting** | Name / natural order (`Episode 2` before `Episode 10`) / size / modified time |
| **Playback** | Play-pause, ±10 s, scrubbing, 0.5x–2.0x speed, volume, fullscreen |
| **Track selection** | Audio and subtitle tracks listed separately; the choice is remembered per file and restored on reopen |
| **Subtitles** | Embedded tracks plus sidecar files in the same folder, matched by base name and episode number first and by similarity as a fallback; ASS styling renders as authored |
| **Progress** | Two modes: this device only, or synced across devices so you can continue on another machine; the list shows progress and percentage |
| **Resume** | Reopening a file offers the previous position: start over or continue |
| **Portable** | Client data, logs and temporary files live in a `PAVL-data/` folder next to the executable; copy the folder and you are done |
| **Tray** | The server lives in the notification area; right-click to add or change shared folders and to read the address and PIN. Changes take effect immediately without a restart |
| **Diagnostics** | Playback failures report a reason and the log location; sensitive fields such as tokens are redacted |

## Screens

| Library | Series and files |
|-|-|
| ![Browse](docs/images/client-browse.png) | ![Series](docs/images/client-episodes.png) |

| Playing | Resume prompt |
|-|-|
| ![Player](docs/images/client-player.png) | ![Resume](docs/images/client-resume.png) |

## Quick start

**Server** (Windows, the machine holding the files)

1. Run `server/pavl.exe`. It moves to the notification area (under the `^` in the taskbar).
2. On first run it asks for a folder to share; you can also pass one:
   `pavl.exe --root "D:\Videos"`.
3. If Windows shows a firewall prompt, allow access.
4. Right-click the tray icon to see the server address and the current PIN.

**Client** (the machine watching)

1. Run `client/pavl_client.exe`.
2. Servers on the LAN appear in the list automatically; otherwise enter the address and port.
3. The first connection asks for the 6-digit PIN shown in the server's tray menu. After pairing it is
   not requested again.

Keyboard controls while playing: `Space` play/pause, `←` `→` seek back/forward 10 seconds,
`↑` `↓` volume ±5, `F` fullscreen, `Esc` leave fullscreen (or go back when not fullscreen).

## How it works

The server depends only on the Dart standard library (`dart:io` / `dart:convert` / `dart:async` /
`dart:math`) and compiles to a single executable of about 6 MB. It does three things:

* scans the configured media roots and builds a browsable tree plus a library index (results are
  cached and invalidated when the disk changes);
* serves files over HTTP Range, handling first-segment, last-segment, out-of-range, cross-tail and
  no-Range requests correctly;
* stores playback progress and metadata write-backs (duration and codec are probed by the client and
  reported back; the server never parses video).

The client is a Flutter application whose playback core is media_kit wrapping libmpv. Because decoding
is local, whether H.265 or AV1 plays depends on the client's hardware decoding support rather than on
the server; conversely, the server has no notion of "supported formats".

A few deliberate trade-offs:

* **No SMB.** HTTP from the server is enough; the client does not mount a network drive, and FFmpeg's
  SMB backend never enters the dependency tree.
* **No transcoding.** Transcoding is the one part of this design that would burn CPU and make the
  interface slow. Leaving it out is what allows the server to be this small.
* **The PIN is unrelated to system accounts.** A home setup does not need an account system; a one-time
  PIN exchanged for a token is sufficient, and devices are revoked from the server menu.
* **The server does not parse video.** Duration and codec information is written back by a client when
  it opens a file, so files that were never played show their size only.

## Layout

```
PAVL/
├─ server/                     Server (Dart console application)
│  ├─ bin/pavl.dart            Command-line entry point
│  └─ lib/
│     ├─ config.dart           Config storage, media roots
│     ├─ media.dart            Extension kinds, filename parsing, natural order
│     ├─ library.dart          Directory tree, library index, cache, progress, metadata
│     ├─ auth.dart             PIN pairing, tokens, device management
│     ├─ discovery.dart        UDP broadcast discovery
│     ├─ streaming.dart        HTTP Range file serving
│     ├─ subtitle_match.dart   Sidecar subtitle matching
│     ├─ native_dialogs.dart   Native folder picker and message boxes
│     ├─ tray.dart             Tray icon and menu
│     ├─ tray_icon.dart        Embedded tray icon asset
│     └─ pavl_server.dart      Routing and authentication
├─ client/                     Flutter client (Windows)
│  ├─ lib/api/                 HTTP client and LAN discovery
│  ├─ lib/store/               Local settings and portable data directory
│  ├─ lib/player/              Playback controller wrapper
│  ├─ lib/ui/                  Connect, browse, player, settings, pairing
│  ├─ lib/util/                Logging and natural ordering
│  └─ assets/fonts/            UI font and its license
├─ scripts/                    Build, packaging and UI verification scripts
└─ docs/images/                Documentation screenshots
```

## Building

**Server**

```
cd server
dart pub get
dart compile exe bin/pavl.dart -o ../build/pavl.exe
```

**Client** (Windows)

```
python scripts/setup_media_kit_deps.py    # pre-fetch libmpv and ANGLE
cd client
flutter pub get
flutter build windows --release
```

`setup_media_kit_deps.py` downloads the libmpv and ANGLE prebuilt packages that media_kit needs into the
expected location, so that the CMake build does not have to fetch them itself. Behind a proxy or on a
slow connection this step is what prevents the build from failing with an integrity error.

**Packaging**

```
python scripts/package.py --zip
```

The result lands in `dist/PAVL-<version>/`: `server/` and `client/` each carry a short readme, and the
root has an overview. `--zip` also produces an archive.

## Conventions

* Scripts are Python and UTF-8; build, packaging and UI screenshot helpers all live in `scripts/`.
* Do not batch-edit Dart sources with regular expressions; use exact literal replacements.
* Generated files stay out of the repository: `build/`, `client/build/`, `dist/`, `.dart_tool/`,
  temporary directories.
* Documentation and screenshots never contain a real environment: addresses use examples such as
  `192.168.1.10`, devices are named by platform only, and local paths, accounts and ports appear only
  where the build truly requires them.

## Platform status

| Platform | Status |
|-|-|
| Windows server | ✅ Complete |
| Windows client | ✅ Complete |
| macOS / Android / iOS / Android TV | Not started |
| Apple TV | Out of scope |

The protocol and routes do not depend on Windows; porting the server mainly means replacing the tray
icon and the native dialogs.

## Known limitations

* The client ships for Windows only; on other platforms the server has no tray menu.
* The firewall port must be allowed manually; there is no self-check yet.
* Poster and synopsis support is exposed by the API but not surfaced in the UI.
* The aggregated library view (recently played, filter by kind) is served by the API but not yet used
  by the client.

## License

The code is original work released under the MIT license; see [LICENSE](LICENSE).

Third-party components bundled with the client:

* **libmpv** (LGPL-2.1-or-later). The build shipped with the client has its GPL components disabled and
  links libmpv dynamically; `libmpv-2.dll` and its companion libraries under `client/` are this
  component.
* **UI font MiSans**, distributed under the Apache License 2.0. The full variable font `MiSansVF.ttf` is
  bundled without subsetting or modification; the license requires keeping the license and notice files
  with any redistribution, and both are in the repository:
  * `client/assets/fonts/MiSans-LICENSE.txt` — the full Apache License 2.0 text
  * `client/assets/fonts/NOTICE.txt` — font origin, usage and no-modification statement
