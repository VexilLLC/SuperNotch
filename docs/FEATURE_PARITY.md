# Feature scouting and implementation map

Reviewed 17 September 2026. SuperNotch is an independent native macOS implementation with a substantial working subset. It is **not feature-complete, pixel-exact, or connected to the reference product's proprietary services or extension SDK**. “Implemented” below means executable code exists, not that every external integration has passed end-to-end testing.

## Reference and counting

Publicly available product material was used during early feature research. This is a dated inventory rather than a promise that any external catalogue will remain unchanged. Names identify reference feature categories; implementation descriptions below describe this repository.

No proprietary binaries, artwork, or source code are incorporated in the implementation. The app uses its own SwiftUI layout, system symbols, native icons, and standard macOS frameworks.

## Core surfaces

| Area | Implementation | Remaining work |
| --- | --- | --- |
| Notch and island | `App.swift`, `IslandSurface.swift`: native floating panels, hover expansion, compact/expanded presentation, optional additional displays. | Extensive per-display geometry, gesture handling, fullscreen/Mission Control rules, wallpaper blending and animation matching are absent or unverified. |
| Compact widgets | `CompactNotes.swift`, `CompactAgenda.swift`, `IslandSurface.swift`: in-island notes editing with persisted draft, EventKit agenda/reminders, focus controls and live CPU/storage; persisted widget order/visibility, last selection and four Home arrangements. | Arbitrary paired compositions, drag-based rearrangement and the remaining tool widgets are incomplete. |
| Main interface | `Views.swift`: dark workspace, sidebar navigation, settings, overview and feature catalogue. | The separate main workspace is our design choice; it does not reproduce the reference's interaction model exactly. |
| Command center | `CommandPalette.swift`: Option-Space palette with fuzzy app/action search, recent suggestions, inline clipboard browsing, saved shell commands and validated local extension manifests. | No remote extension store, JavaScript/React runtime, account sync or automatic third-party package installation. |
| File shelf | `FileShelf.swift`: file/folder references, bookmarks, pinning, chooser, search, drag in/out, ImageIO and Quick Look thumbnails with native icon fallback, open/reveal, Quick Look and optional unpinned retention. | Multi-selection drag bundles and configurable drop destinations are incomplete. Live file-change monitoring and thumbnail behavior across all file types need broader coverage. File removal deletes references only. |
| Basket | `BasketController`, `BasketSurface.swift`: compact borderless panel with up to twelve named file collections, a shared switcher, rename and merge, item moves, plus optional drag-jiggle summon. | Simultaneously displaying several independent basket windows, adjustable jiggle sensitivity and full drag lifecycle handling. |
| File sharing | Shelf context actions invoke AirDrop, Mail and Messages. `LocalSharing.swift` supplies temporary HTTP downloads. | No hosted cloud uploads, Dropbox/Drive integration, iPhone sync or LocalSend protocol. |
| Clipboard | `Clipboard.swift`, `CommandPalette.swift`: text, links, RTF, images and file references; clipboard history inside the command palette, full library, search/type/tag filters, editable tags, hex/RGB color previews, pins, source-app badges, duplicates, copy/direct paste, pause. | Image OCR indexing, sync and additional reference layouts. Concealed data filtering depends on source apps marking content. |
| Media | `SystemServices.swift`, `AudioDevices.swift`: Music/Spotify playback, seeking and current-track artwork; output devices and supported output volume/mute. | Full queue management, lyrics, generalized browser/player adapters and native AirPlay discovery. Current artwork requires live verification with authorized playback. |
| System activity | `SystemMonitor`, `SystemActivities.swift`, `BatteryInsights.swift`, `ChargeLimiter.swift`, `ChargeLimitCore`, and `SuperNotchChargeHelper`: battery health/cycles/temperature, hardware charge and power flow, adjustable charge and heat alerts, application resource estimates, network reachability/interfaces, memory, uptime, mounted volumes/eject, Caps Lock and locally observed event log; brief island activity strips for charging, battery thresholds, Caps Lock, connectivity, new shelf references and focus sessions. On supported Macs, the optional administrator-approved helper can hold a charge target, sail before resuming, discharge to the target, top up once, and control the MagSafe LED when available. | Charge control uses undocumented AppleSMC behavior and needs broader model coverage; unsupported Macs fall back to alerts. Calibration automation, brightness/keyboard-brightness replacement HUDs, verified VPN sessions, headphone battery, Focus indicators and low-power shortcuts remain. |
| Customization | Preferences include hover behavior, island form, multiple displays, outline, accent and clipboard toggle; launch-at-login uses ServiceManagement. | Drag-based widget arrangement, fine-grained activation beyond widget visibility, broad appearance presets and complete localization. |
| Lock screen | None. | Secure-session UI and controls. |
| Companion devices | None. | iOS app, encrypted device pairing, widgets, Siri and sync service. |
| Extension platform | `Extensions.swift` presents available tools and explicitly planned capabilities. | It is a built-in catalogue, not a plugin loader, store, sandbox, third-party SDK implementation or runtime enable/disable system. |

## All 37 named Droplets

Status: **Implemented subset** means the named area has a functional counterpart; it does not mean full equivalence. **Missing** means no corresponding feature implementation. Source filenames are under `Sources/SuperNotch`.

| # | Reference name | Status / source | Actual scope and gaps |
| --- | --- | --- | --- |
| 1 | AI Background Removal | Implemented subset — `CaptureTools.swift` | Apple Vision foreground masking to PNG. Detection quality and hardware/language variations need broader testing. |
| 2 | Alfred Workflow | Implemented subset — `ExternalActions.swift`, `integrations/alfred` | Seven keywords open island, clipboard, shelf, basket, notes, agenda and focus controls through validated app URLs. Workflow import and external URL launch need end-to-end coverage. |
| 3 | Element Capture | Implemented subset — `CaptureTools.swift` | Interactive region screenshot saved to Pictures and shelf. No element segmentation or styled screenshot editor. |
| 4 | Finder Services | Implemented subset — `QuickActions.swift` | Native Services provider sends selected files to shelf/basket. Finder discovery requires the packaged app and macOS service registration. |
| 5 | Spotify Integration | Implemented subset — `SystemServices.swift` | AppleScript metadata, playback and seek. No account API, complete queue or lyrics. |
| 6 | Voice Transcribe | Implemented subset — `SensorTools.swift` | M4A recording and Apple Speech transcription; on-device by default, online recognition only after explicit opt-in. No bundled speech model or universal language guarantee. |
| 7 | Window Snap | Implemented subset — `CommandTools.swift` | Accessibility-based window layouts. Behavior depends on target app window constraints and permission. |
| 8 | Video Target Size | Implemented subset — `FileProcessing.swift` | AVFoundation quality presets and MP4/MOV export with progress/cancel; encoder size estimate when available. No exact target-byte-size solver. |
| 9 | Termi-Notch | Implemented subset — `CommandTools.swift` | User-entered shell commands, working directory, bounded output and cancellation. Not a terminal emulator or interactive PTY. |
| 10 | Hosted Cloud | Missing | Local File Links is temporary LAN/loopback HTTP only. It has no hosted storage, public URLs, account system or cloud retention. |
| 11 | Apple Music Integration | Implemented subset — `SystemServices.swift` | Music.app scripting for metadata/playback/seek. No complete library/queue integration. |
| 12 | Notifications | Missing | No system notification mirror or reply adapter. |
| 13 | High Alert | Implemented subset — `Productivity.swift` | `caffeinate` prevents idle/display sleep while enabled. No full rules engine or companion control. |
| 14 | Calendar | Implemented subset — `Productivity.swift` | EventKit agenda and reminders, add/complete reminders. No natural-language event parser or full calendar editor. |
| 15 | Camera | Implemented subset — `SensorTools.swift` | User-started live camera preview. No full camera utility suite. |
| 16 | Pomodoro | Implemented subset — `Productivity.swift` | Adjustable deadline-based countdown, pause/reset, persisted state and completion sound. No Apple Clock synchronization or complete automated cycle/statistics system. |
| 17 | LiquidMouse | Missing | No cursor styling/effects engine. |
| 18 | Lyrics | Missing | No timed-lyrics provider or rendering. |
| 19 | Meetings | Missing | No conferencing-app adapters or meeting controls. |
| 20 | Notes | Implemented subset — `Productivity.swift` | Persistent local quick notes with editing, deletion and copying. No cross-device synchronization. |
| 21 | Thunderstorm | Implemented subset — `CommandTools.swift` | Spotlight-backed file search and installed-app launcher. No app uninstaller or complete widget/search action ecosystem. |
| 22 | PDF Compress | Implemented subset — `FileProcessing.swift` | DPI/JPEG-controlled image-only PDF output. Loses searchable text, links, forms and accessibility structure; output may grow. |
| 23 | Agents | Implemented subset — `Integrations.swift` | Validated local `agents.json` activity feed. External tools must write events; there are no automatic Codex/Claude/Cursor adapters. |
| 24 | Thaw | Missing | No menu-bar item manager. |
| 25 | Mechey | Implemented subset — `QuickActions.swift` | Optional key sounds with permission-aware event monitoring. No extensive mechanical-switch sample library. |
| 26 | Converter | Implemented subset — `CaptureTools.swift`, `FileProcessing.swift` | PNG/JPEG/TIFF/HEIC conversion, batch PNG resizing and supported AVFoundation video export. No arbitrary document/audio format conversion. |
| 27 | LocalSend | Missing | LAN HTTP sharing uses our own links; it cannot discover or transfer through LocalSend clients. |
| 28 | Obsidian | Implemented subset — `Integrations.swift` | User-selected Markdown vault, note list/edit/save, conflict and path checks. No Obsidian plugin API or automatic vault discovery/sync. |
| 29 | Weather | Implemented subset — `Integrations.swift` | Open-Meteo city search and forecast requests. Requires internet; no system location tracking. |
| 30 | System Stats | Implemented subset — `SystemServices.swift`, `SystemPerformance.swift`, `BatteryInsights.swift` | Live CPU user/system/idle percentages and two-minute history, memory pressure, load averages, uptime, disk throughput, best-effort GPU utilization, startup-volume health, battery health/power-flow telemetry, app CPU/memory impact estimates, and network availability. GPU registry counters are not exposed on every Mac; app impact is explicitly not macOS Energy Impact. |
| 31 | OCR | Implemented subset — `CaptureTools.swift` | Vision image recognition and PDF embedded/scanned text extraction. No automatic clipboard OCR indexing or live selection overlay. |
| 32 | Audio Control | Implemented subset — `AudioDevices.swift` | System output enumeration/selection and supported volume/mute. **No per-app audio mixing or audio taps.** |
| 33 | Kaset YouTube Music | Missing | No Kaset adapter. |
| 34 | Ring | Implemented subset — `QuickActions.swift` | Configurable six-slot cursor action panel and global shortcut. Limited built-in action list. |
| 35 | Emoji Picker | Implemented subset — `SensorTools.swift` | Searchable curated emoji choices and copy. No exhaustive Unicode catalogue. |
| 36 | Mac Duo | Missing | No corresponding integration. |
| 37 | Teleprompter | Implemented subset — `Teleprompter.swift` | Native scrolling reader, speed/font controls, mirrored display and fullscreen window. No complete equivalence claim; interactive behavior needs broader testing. |

`SystemActivitiesView` and `TeleprompterView` are integrated into Tools as Activity and Prompter. Their source compiles. The activity log records this app's observations, not system notification history; it makes no VPN-status claim.

## Verification boundary

Build success verifies compilation/linking, not feature parity. Repository tests currently exercise clipboard privacy/persistence/pins, image conversion geometry/original preservation, command output/error/bounded-storage handling, vault edit conflicts/agent validation, and byte-exact local HTTP transfers with rejected unknown routes and unsupported methods. Separate development smoke tests exercised PDF rasterization, resize, output naming and a real loopback file transfer, including invalid routes and stop behavior. Additional smoke scripts are complementary to the repository regression suite.

Permission-dependent media, camera, microphone, speech, calendar, Accessibility, Finder services, charge-control hardware and multi-display behavior require further interactive coverage. Real video export and extended-duration/network-failure cases also need test media and device coverage. Native styling is present; pixel comparison against the reference has not been completed.
