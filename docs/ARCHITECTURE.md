# Architecture

SuperNotch is a Swift Package executable for macOS 14 and later. It uses SwiftUI for views and AppKit for panels, native dialogs, application integration and clipboard behavior. The package declares Swift tools 6.0 and Swift language mode 5. There are no external Swift package dependencies.

## Build and packaging

- `swift build` builds the development executable.
- `swift test` runs `Tests/SuperNotchTests`.
- `scripts/build-app.sh` builds and assembles the app bundle with `Resources/Info.plist`, then applies an ad-hoc signature.
- An ad-hoc build is not Developer ID signed or notarized. Distribution signing, notarization, updates, release automation and broad OS/device validation remain work.
- Use the packaged app for permission and Services testing. Launching a raw Swift executable is not equivalent to testing the final bundle's identity, privacy descriptions and Services registration.

## Module responsibilities and entry points

All source files are compiled into one executable target; these are responsibility boundaries, not independently loadable plugins.

| File | Primary entry points | Responsibility |
| --- | --- | --- |
| `App.swift` | `SuperNotchApp`, `AppDelegate`, `AppState.shared`, `Preferences.shared` | Startup, menu bar, shortcuts, main window, panel placement, app navigation/preferences. |
| `Views.swift` | `WorkspaceView`, `DashboardView`, `SettingsView` | Native split-view workspace and overview. |
| `SettingsWindow.swift` | `SettingsWindowController`, `SettingsSection` | Custom dark Settings window (⌘,) with live island preview and island-styled controls. |
| `NowPlayingBridge.swift`, `Helpers/NowPlaying/` | `NowPlayingBridge`, `NowPlayingSnapshot` | System-wide Now Playing helper hosted by `/usr/bin/perl`, streamed as JSON lines. |
| `DesignSystem.swift` | `cardStyle`, `SymbolTile`, `InlineMessage` | Appearance-adaptive surfaces shared by workspace pages. |
| `Extensions.swift` | `ToolGroup`, `ExtensionsView`, `ExtensionItem` | Sidebar tool routing and available/planned capability catalogue. |
| `CommandPalette.swift` | `CommandPaletteController`, `CommandPaletteStore` | Option-Space command center, inline clipboard history, application search, saved commands and validated local extension manifests. |
| `IslandSurface.swift`, `IslandActivity.swift`, `IslandActivityController.swift` | `IslandView`, `IslandActivityController.shared` | Notch silhouette, compact widgets, transient activity strips and expiry. |
| `CompactShelf.swift`, `BasketSurface.swift`, `FileThumbnail.swift` | `CompactShelfView`, `FileThumbnailView` | Compact file surfaces, native previews and bounded thumbnail cache. |
| `CompactNotes.swift`, `CompactAgenda.swift` | `CompactNotesView`, `CompactAgendaView` | In-island note drafts, events and reminders. |
| `ClipboardPanel.swift`, `ClipboardStrip.swift` | `ClipboardPanelController.shared` | Floating history strip and keyboard focus. |
| `MediaArtwork.swift` | `MediaArtworkView` | Bounded artwork loading, downsampling and shared rendering. |
| `SystemPerformance.swift` | `SystemPerformanceMonitor.shared`, `SystemPerformanceView` | View-scoped native CPU history, memory pressure, load average, uptime, disk throughput, best-effort GPU activity, and startup-volume capacity sampling. |
| `BatteryInsights.swift`, `ChargeLimiter.swift`, `ChargeLimitCore/`, `SuperNotchChargeHelper/` | `BatteryInsightsMonitor.shared`, `ChargeLimiter.shared`, `ChargeLimitPolicy` | Battery health, power-flow telemetry, alerts and app resource estimates. An optional administrator-approved launch daemon applies model-aware AppleSMC charge control on supported Macs. |
| `BasketSwitcher.swift` | `BasketSwitcher`, `ShelfMoveMenu` | Named basket management and destination menus across file surfaces. |
| `WidgetPreferences.swift` | `WidgetPreferences.shared`, `WidgetPreferencesEditor` | Ordered visible widgets, persisted layout validation and settings rows. |
| `ExternalActions.swift` | `ExternalActionParser`, `ExternalActionDispatcher` | Action-only app links used by the Alfred workflow. |
| `FileShelf.swift` | `FileShelfStore.shared`, `FileShelfView`, `BasketController.shared` | Bookmark-backed references, file interactions, shared floating basket. |
| `Clipboard.swift` | `ClipboardStore.shared`, `ClipboardHistoryView` | Pasteboard polling, privacy-type filtering, bounded unpinned history, copy/paste. |
| `SystemServices.swift` | `SystemMonitor.shared`, `MediaController.shared`, `MediaView` | Battery/memory/network readings, Music/Spotify scripting and playback UI. |
| `AudioDevices.swift` | `AudioDevicesStore`, `AudioDevicesView` | CoreAudio device discovery, selection, output volume/mute. |
| `Productivity.swift` | `ProductivityStore.shared`, `ProductivityView` | Countdown, quick notes, EventKit agenda/reminders, keep awake. |
| `CaptureTools.swift` | `CaptureToolsView`, `CaptureToolsModel`, `CaptureTransforms` | Screenshots, OCR, subject masking and image conversion. |
| `FileProcessing.swift` | `FileProcessingView`, `FileProcessingModel`, `ProcessingTransforms` | Video export, PDF raster compression and batch resize. |
| `CommandTools.swift` | `CommandToolsView`, `CommandToolsModel` | Spotlight/app search, shell command execution, Accessibility window placement. |
| `SensorTools.swift` | `SensorToolsView` | Camera, audio recording, Apple Speech and emoji selection. |
| `QuickActions.swift` | `QuickActionsView`, `QuickRingController`, `FinderShelfServices`, `KeySoundStore` | Cursor shortcuts, Finder Services and optional keyboard sounds. |
| `Integrations.swift` | `IntegrationsView`, `IntegrationsModel` | Markdown vault editing, Open-Meteo requests and local agent event feed. |
| `LocalSharing.swift` | `LocalSharingView`, `LocalSharingModel`, `LocalFileHTTPServer` | Temporary loopback/LAN HTTP file downloads. |

`Teleprompter.swift` exposes `TeleprompterView` and `TeleprompterStore.shared`, with native scrolling, mirroring and a fullscreen reader. `SystemActivities.swift` exposes `SystemActivitiesView` and `SystemActivitiesModel`, observing network interfaces, mounted volumes and Caps Lock, plus eject controls and a local observation log. Both are integrated in Tools and compile. Activity monitoring starts at application launch and is event-driven through native path, modifier and workspace notifications; its log is not system notification history and does not infer VPN status.

The feature catalogue is descriptive. Its available rows route to built-in views; planned rows do not execute placeholder integrations. It is not a runtime extension system.

## State and concurrency

Observable models generally isolate UI state to `MainActor`. Shared stores keep the shelf, media, productivity and navigation coherent across surfaces. Tool views use view-owned models where appropriate. Native `NSPanel` instances host SwiftUI views for the island, basket and action ring.

Image/PDF transformations and shell work run away from the UI thread. Video export uses AVFoundation's asynchronous export session. Camera capture has a dedicated queue. Local sharing owns a serial Network-framework queue and sends small state updates back to the main actor. Pasteboard change-count capture and live system readings still require low-frequency polling. Activity detection, interface/volume observation, shelf expiry, media progress and focus updates are event- or state-scoped so they do not install unconditional high-frequency timers.

## Local persistence and data movement

| Location / store | Contents |
| --- | --- |
| `~/Library/Application Support/SuperNotch/shelf.json` | File paths, security bookmarks, pins and timestamps. Files remain in their original locations. |
| `~/Library/Application Support/SuperNotch/clipboard-history.json` | Clipboard metadata, SHA-256 payload identities and bounded JPEG previews. Stored locally without application-level encryption. |
| `~/Library/Application Support/SuperNotch/clipboard-payloads-v1/` | Per-entry image and rich-text payloads, created by new captures or atomic migration from legacy inline history. |
| `~/Library/Application Support/SuperNotch/Recordings/` | User-started M4A recordings. |
| `~/Library/Application Support/SuperNotch/agents.json` | External producer's versioned activity data; read/validated by the integrations view. |
| `~/Pictures/SuperNotch Captures/` | Region captures with unique filenames. |
| `UserDefaults` | Preferences, quick notes, countdown deadline/state, action-ring choices, teleprompter script/settings and last recording path. |
| `/Library/Application Support/SuperNotch/ChargeLimit/` | Optional helper configuration, request state and status. The helper is installed only after administrator approval; status and helper-owned state are root controlled. |
| User-selected output destinations | Converted images, resized copies, raster PDFs and exported video. |
| User-selected Markdown vault | Explicit note edits; existing content is checked for outside changes before saving. |

Clipboard unpinned history is trimmed toward 200 entries and 40 MB; each captured text/image payload is limited to 5 MB. Pinned entries can prevent total-history limits from being fully enforced. Large payloads are written before the metadata archive is atomically replaced, loaded lazily, protected with owner-only file permissions, and pruned after their entries disappear. Persisted payload identities make duplicate checks constant-memory and avoid archive I/O on the main thread. Legacy inline archives remain readable and migrate without changing entry IDs, ordering, pins, tags or payload bytes. Privacy markers such as concealed/transient/password types are excluded; this cannot detect secrets copied by apps that do not mark them.

Shelf deletion removes references, not source files. Transform tools choose new output names and reject the original resolved path. Video uses a staging file before replacing an explicitly chosen destination. PDF compression creates image-only pages and warns about losing document structure. Batch resizing chooses unused names; animated input exports the first frame.

The default architecture is local, but it is not universally offline:

- Weather sends the entered city and selected coordinates to Open-Meteo.
- Apple Speech is on-device by default. The user may explicitly enable Apple's online recognition when needed.
- AirDrop/Mail/Messages hand selected attachments to macOS sharing services.
- Commands execute exactly the shell work the user starts and can themselves access network or files.
- Local File Links opens a temporary HTTP listener only after Start. Loopback is default; LAN requires the toggle. It has no cloud backend or iOS companion.
- The optional charge controller writes its user-owned configuration for a root launch daemon. It uses undocumented AppleSMC keys, restores normal charging when removed, and reports unsupported hardware instead of attempting control.

## Local sharing design

Each session gets an opaque random token and an exact per-file route. The listener binds either loopback or a discovered private IPv4 address. Requests are restricted to private IPv4 peers and GET; paths are matched directly against selected-file routes. The server never resolves a requested filesystem path or serves directories. Open file descriptors are checked as regular files.

Headers are limited to 8 KiB, incomplete headers time out, active connections are capped at eight, and file data is streamed in 64 KiB chunks. Stop or one-hour expiry cancels the listener/connections. There is no TLS, account/password layer, recipient authentication, LocalSend discovery or public-hosting integration. Anyone who obtains a valid link and can reach the listener can download its file. Firewall and network client isolation can prevent LAN access.

## Permissions and integration dependencies

| Capability | Dependency |
| --- | --- |
| Region screenshots | macOS screen recording/capture access when required by the OS. |
| Music/Spotify control | Automation permission to script the chosen installed/running app. |
| Window snap, direct paste, global key monitoring | Accessibility and/or OS input-monitoring policy. Features report missing access rather than granting it themselves. |
| Camera | Camera permission, requested when starting preview. |
| Voice recording | Microphone permission, requested when recording. |
| Transcription | Speech Recognition authorization and available language support. |
| Agenda/reminders | EventKit full access requested by the relevant Connect action. |
| Login item | ServiceManagement registration and system Login Items policy. |
| Local sharing | Reachable local interface and firewall/local-network policy. |
| Finder Services | Packaged bundle's Services declaration and macOS discovery. |
| Charge control | Supported Apple Silicon hardware, bundled helper, explicit administrator approval and undocumented AppleSMC behavior. Basic battery monitoring and alerts do not require the helper. |

There is no blanket permission requirement for opening the basic app. Permission flows must be tested from the actual app bundle, including denial and later re-enabling. The build is not an App Store sandbox design; security-scoped bookmarks help retain references but are not a claim of comprehensive sandbox confinement.

## Verification and remaining engineering work

Repository tests currently cover clipboard privacy markers, pin/persistence behavior, image conversion geometry/source preservation, command output/error/bounded-storage handling, vault edit conflicts/agent validation, and byte-exact local HTTP transfers with rejected unknown routes and unsupported methods. Development-only smoke tests additionally covered image resize, collision-safe output naming, PDF page geometry, source preservation and a byte-exact 2.1 MB loopback HTTP transfer, unknown/traversal route rejection, unsupported methods and listener shutdown.

Compilation and smoke checks do not cover every view, permission state, media file, language, display topology or sleep/wake transition. Important next work includes reproducible video fixtures, LAN failure/slow-client tests, persistent-model migrations, accessibility and keyboard-navigation audit, memory/energy profiling, larger-file stress tests, and automated UI coverage. Native API availability alone does not establish behavior on every Mac.

For the current scope and explicit missing capabilities, see [Feature scouting and implementation map](FEATURE_PARITY.md).

## Basket persistence

The shelf archive atomically stores version, named baskets, active basket and all file references in `shelf.json`. Legacy arrays load into Main; the first write retains their bytes in `shelf.json.legacy-backup`. Unknown or unreadable archives are preserved and cannot be overwritten by ordinary shelf changes. Retention applies across collections, while clear and sharing target the active collection. Asynchronous drops and choosers capture a destination ID; a destination merged before completion falls back to Main. Rename and merge dialogs capture their own target IDs.
