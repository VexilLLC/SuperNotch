# Island visual refinement

15 September 2026.

Goal remains active: bring SuperNotch's everyday interaction and visual feel closer to the reference. Full feature and visual parity are not established.

## Current change

- Dedicated compact island presentations replace full workspace views inside the overlay.
- Home combines an actual clock/date, connectivity and battery readings, media controls and focus timer.
- Tray uses horizontal native file icons, compact spacing and real Add/Basket/AirDrop actions.
- Home, Tray and Widgets use small pill navigation.
- Notched screens use a silhouette with concave top shoulders; notchless/floating mode uses rounded geometry.
- Each panel receives its own display's notch dimensions. Explicit floating mode sits below the physical notch.
- Panel changes animate over 0.2 seconds, respecting macOS Reduce Motion.
- Workspace opens on initial launch; later launches remain in the notch/menu bar until opened.

## Delegation

CompactShelf.swift was implemented by a GPT-5.6 Luna subagent with max reasoning. Root implemented the compact home, media/focus cards, silhouette and window integration.

## Verification boundaries

Five existing regression tests pass after integration. These protect storage/processing paths, not appearance. The installed release was visually inspected on Home, Tray and Widgets. The compact-state click opened Home; navigation and Escape dismissal were exercised. The tray action row was revised after native inspection revealed an overly wide popup. External display geometry, transitions during screen changes and drag gestures still need broader coverage.

Reference behavior was studied from publicly visible notch-style utilities.

## Floating clipboard and basket

- Added a transient bottom clipboard panel, with autofocus search, horizontal content cards, type filters, pinned scope, explicit Copy/Paste actions and Open Library.
- New copies retain optional source-app metadata. A regression test checks older history still decodes without those fields.
- Panel dismissal releases its content view; opening starts a fresh search session. Escape and outside clicks dismiss it.
- Replaced the basket utility window with a 360 × 300 borderless charcoal surface, real file tiles, compact actions and a draggable header. Drag summons avoid taking keyboard focus.
- GPT-5.6 Luna subagents at max reasoning implemented the two surfaces. Root integrated window behavior, source metadata, migration coverage and refinements following native screenshots.
- Six regression tests pass. Native UI checks verified clipboard autofocus, capture, pin scope, full-library navigation and basket Escape dismissal. Screenshots revealed excess clipboard height and a stretched basket menu; both were tightened. Cross-app Paste, external Finder drag/drop and multi-display positioning still need end-to-end validation.

## Island live activities

- Added transient 420pt-wide activity strips below the physical-notch header, with category glyphs, concise state and an optional level rail. The existing native frame animation contracts back after three seconds.
- Startup observations and unchanged polling values are silent. Newer activities replace older ones safely. Detection covers charging state, low-battery threshold crossings, Caps Lock, network availability, shelf additions and focus transitions.
- Expanded workspace content stays available; activity presentation does not request keyboard focus. A Settings switch disables the strips. The collapsed island displays a running focus countdown.
- Four regression tests cover baseline silence, change detection, battery thresholds, shelf identity changes, focus completion and activity replacement/expiry.
- Installed native UI inspection captured a real Focus started strip, its countdown and its automatic contraction. This does not establish charging, hardware-key or network transitions on all hardware.
- Activity strip presentation was delegated to GPT-5.6 Luna at max reasoning; root implemented event detection, lifecycle, geometry and tests.

Native macOS volume/brightness HUD suppression is not implemented.

## Current-track artwork

A GPT-5.6 Luna subagent at max reasoning added a shared artwork view used in both the compact island player and the full player. Music artwork comes from its scripting API; Spotify exposes an artwork URL. Fetches are asynchronous, capped at 10 MiB, decoded to at most 1024 pixels on the longest side, cached by track and guarded against stale source/track results. Failed loads retry after a delay. The fallback remains visible when artwork is missing.

These paths start after Connect player. Compilation and an image-decoding fixture test do not establish live-player compatibility or permission behavior; that remains unverified.

## Useful widgets inside the island

Notes, Agenda and Focus now have dedicated compact compositions under Widgets. Notes can create/edit/save/copy through the existing local store; unfinished drafts use AppStorage because these panels are hosted by AppKit. Agenda shows real EventKit events/reminders after explicit access, with refresh, add and completion controls. Focus adds presets, reset and Keep Awake beside its timer.

Menu actions and registered shortcuts open Notes or Agenda directly; the cursor ring's notes action now opens the widget. Full Notes/Agenda links retain access to the larger workspace. Calendar and reminder stores recheck authorization, refresh on EventKit changes and reject stale reminder callbacks.

GPT-5.6 Luna subagents at max reasoning implemented the two compact views. Root integrated navigation, draft storage, EventKit lifecycle and layout refinements. Native UI checks verified a draft survived collapse/reopen, saving produced a real note, Calendar/Reminders showed explicit connect states without prompts, and focus presets changed the timer before restoring 25 minutes. A harmless verification note remains in local storage. Authorized EventKit read/write and OS-global shortcut dispatch remain unverified.

The shelf widget follows the same local file-reference model as the workspace.

Final widget release checks: the saved note survived relaunch. An unfinished edit then survived another app restart with its editing identity intact; Save updated the existing note rather than duplicating it. Full Notes → island → Full Agenda selected Agenda in the same existing workspace. All eleven existing regression tests passed after integration, and the installed release passed ad-hoc signature verification.

## File previews and retention

ImageIO raster decoding and Quick Look document thumbnails now supply the island, workspace and basket tiles, with aspect-fit images and a native file-icon fallback. Requests use file metadata in their cache keys and a bounded cache. The compact tray uses the island's black background; selecting a file exposes Space to preview.

Retention is optional and defaults to keeping references until removal. One hour, one day and one week settings expire unpinned references on launch and during use; pins remain. Removing or expiring references releases unused security-scoped access. Two storage regressions check exact expiry, pins, startup cleanup, persistence and unchanged original file contents.

The thumbnail component and cancellation tests were delegated to GPT-5.6 Luna at max reasoning. Root integrated the surfaces, retention policy, storage lifecycle and tray keyboard preview.

## CPU, storage and local shortcuts

The overview and Activity tool now include a live CPU gauge, user/system/idle breakdown and startup-volume storage bar. The installed release showed live samples in both locations. Sampling uses a utility queue, balanced Mach resources and generation checks; view leases stop unnecessary polling when these surfaces disappear. CPU starts with a fresh baseline; cached storage remains visible during its thirty-second refresh interval.

Seven validated app-link routes and an Alfred workflow open common tools. Focus links reveal controls without changing the running timer. Parser/dispatcher tests and workflow archive validation pass. External launch and Alfred import remain unverified because the browser's security policy blocked the local link-test page.

Both new features were delegated to GPT-5.6 Luna at max reasoning. Root integrated navigation, cold-launch routing, URL registration, packaging and native UI checks. The combined regression suite passes 24 tests.

## Configurable island layout

The island now offers Notes, Agenda, Focus and System widgets in a persisted user-selected order. Settings provides visibility toggles, accessible move controls and reset. At least one remains enabled, and explicit Notes/Agenda entry reveals its target. The selected widget survives relaunch. Four Home arrangements cover Music + Focus, Focus + Music and either tool alone. Command–1/2/3 switches pages while the island has keyboard focus.

Native validation reordered System, hid Agenda, selected System and changed Home to Focus + Music. All survived terminating and reopening the app. All three keyboard page shortcuts worked. The default Home arrangement and complete default widget order were then restored. Model tests cover persistence, malformed numbers, duplicate IDs and move bounds; the full suite passes 28 tests.

The System widget uses the island's black background without an enclosing card to keep the compact surface visually quiet. Custom arbitrary widget pairs and drag-based rearrangement are still incomplete. The preference model/editor were delegated to GPT-5.6 Luna at max reasoning; root integrated layout, routing, keyboard handling and native checks.

## Named baskets

The tray, floating basket and workspace now share a basket-name switcher. Up to twelve collections support creation, rename, per-item moves and merging back into the first basket. Clear and sharing operate on the selected collection. Existing references load into Main, and the first archive write retains a legacy backup. Drops and choosers capture their destination; dialogs capture their target collection.

Native checks created Review, moved LICENSE to it, verified the floating basket and relaunch persistence, renamed it and merged it back into Main. The two original reference IDs and paths remained. Migration tests caught and fixed `/var` versus `/private/var` duplicate identity after bookmark restoration. Native testing also caught a rename-sheet state bug; dialog payloads now carry the target directly. The full suite passes 31 tests.

The switcher and destination menu were delegated to GPT-5.6 Luna at max reasoning. Root implemented persistence/migration, collection operations, integration and end-to-end checks. Multiple simultaneous basket windows and broader drag lifecycle behavior remain incomplete.

## Native workspace redesign

The workspace window now uses standard macOS structure instead of a custom dark imitation:

- `NavigationSplitView` with a system sidebar (Library, Focus & Media, Tools, All Features), item-count badges and a live focus countdown. Each tool group is its own sidebar destination; the horizontal pill tabs are gone.
- Unified toolbar with window title/subtitle (live counts and state), plus Clipboard Strip, Floating Basket and Show Island buttons. Clipboard and All Features use toolbar search.
- Follows the system Light/Dark appearance and accent color (new "System Accent" default). Workspace surfaces use semantic fills, separators and text-background colors from `DesignSystem.swift`. The island, clipboard strip, basket and cursor ring stay dark.
- While the workspace is open, SuperNotch shows a Dock icon, main menu and ⌘-Tab entry, then returns to menu-bar-only mode when the window closes. The window frame is remembered.
- Settings moved out of the sidebar into a standard tabbed Settings window (General, Island, Shelf, Shortcuts, Privacy, About), reachable with ⌘, and from the menu bar item.
- Overview replaces the marketing hero with metric tiles, Quick Actions showing shortcuts, Now Playing controls, Mac status and performance. In-page duplicate titles were removed. Segmented controls hide their labels, and buttons use title case.

Verified: debug build, the full `swift test` suite, and a native screenshot of the Overview in Dark appearance. Light appearance, every tool page and the Settings window still need a visual pass.

## Seamless notch island

- The collapsed island is exactly the display's hardware notch (width from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, height from the top safe-area inset), so it blends into the notch when idle. Displays without a notch use a menu-bar-height tab.
- While music plays or a focus session runs, "ears" either side of the notch show artwork with animated level bars, or the countdown.
- Hover grows the shape slightly with a spring. With Open on hover enabled, a short dwell or a file drag opens it; a click always opens it.
- The panel no longer resizes its window frame. A fixed transparent canvas hosts the shape, and SwiftUI animates the size and the animatable `NotchShape` radii. Opening uses a spring and brings content in from a blur and scale; closing fades and scales content out while the shape springs back into the notch. Reduce Motion swaps in short eases.
- Clicks outside the visible shape pass through to the menu bar (`ignoresMouseEvents` follows the pointer via mouse-move monitors).
- Page navigation moved into the header, left of the notch, with actions on the right, which removes the bottom bar.

Verified with window captures of the collapsed, opening, open and closing states on a notched MacBook. Hover growth, drag-to-open and external displays still need hands-on checks.

## System-wide Now Playing

- New default player source, **Any Player**, follows whatever macOS reports as Now Playing: browsers (YouTube and other sites), Spotify, Apple Music, video players and podcast apps. It needs no Automation permission. Apple Music and Spotify remain as explicit AppleScript sources.
- macOS 15.4 and later only share MediaRemote state with Apple-identified processes. `Helpers/NowPlaying/NowPlayingHelper.m` is compiled by `scripts/build-app.sh` into the bundle and hosted by `/usr/bin/perl` (`now-playing.pl`). It streams JSON snapshots (title, artist, duration, elapsed time, rate, source app, artwork only when it changes) and accepts `toggle`, `next`, `previous`, `seek` and `refresh` on stdin. It exits when SuperNotch closes the pipe, and the Swift bridge restarts it with a crash limit.
- The player, overview and island show the source app's icon as an artwork badge, and the island card gains a live progress bar. Progress is interpolated from the playback rate between snapshots.
- MediaRemote is private API. A future macOS release can change or close it; when the helper is missing (for example an unbundled `swift run`), the UI explains and offers the AppleScript sources.

Verified live with a browser video: title, artist, artwork, source badge, progress and collapsed ears; the helper exits on app quit; snapshot decoding has regression tests. Playback commands and seeking were not exercised to avoid interrupting the user's audio.

## Compact island, click to open, custom Settings

- **Click to open:** hovering the notch only grows it slightly. A click opens it, and so does dragging files onto it (which lands on Tray). Escape or a click anywhere outside closes it; clicks in the island's own popovers and menus don't.
- **Compact island:** each page has its own size. Home is a 372 × 150 pt player below the notch, Tray is 520 × 226 pt and Widgets is 480 × 238 pt; size changes spring between pages.
- **Home player:** artwork with a source-app badge, title and artist, animated level bars, and a white scrubber that thickens on hover and seeks on click or drag. Elapsed and remaining times sit beside it. Below are controls to show the source app, previous, play/pause, next, and an audio-output popover.
- **Floating navigation:** Home, Tray (with its item count) and Widgets sit in a black capsule below the island, next to round Clipboard and More buttons. They spring in after the island opens and count as part of its clickable area.
- **Custom Settings window** (`SettingsWindow.swift`), replacing the stock grouped form:
  - A dark, full-bleed window with a sidebar of colored tiles, large rounded titles and a tinted glow per section.
  - Custom capsule toggles, chip pickers, color swatches, visual Home-arrangement cards and keycap shortcuts.
  - A live, clickable mini island preview that follows the shape settings.
  - A Music page showing the current track and source app.
  - ⌘, and every Settings entry point open it.

Verified with window captures of Home, Tray, and the General, Music and Island settings pages; the full test suite passes. The click-outside close, scrubbing, the audio popover and the Widgets page need hands-on checks.

## Workspace in the island style

The main window now shares the custom Settings design and replaces the earlier native split view. It is a dark, full-bleed window with a sidebar of colored tiles, section labels and a sliding selection. The sidebar shows badges for shelf and clipboard counts, the running focus countdown, and live bars on Now Playing. Each page has a large rounded title, subtitle and tinted glow. Header actions are round buttons plus an Island pill; clipboard and catalog search, filters, pause and clear sit inline rather than in an AppKit toolbar. Quick Actions show keycap shortcuts. The workspace is now always dark, to match the island and Settings.
