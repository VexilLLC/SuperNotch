# Performance audit

Initial audit: 15 September 2026 · MacBook Pro (Apple Silicon, notched display), macOS 15.7, release build (`scripts/build-app.sh`). Follow-up validation: 16 September 2026.

Measured with `proc_pid_rusage` (CPU time, physical footprint, disk I/O, wakeups, billed energy) over 15–20 s windows, `sample` for main-thread call graphs, `vmmap`, and `leaks`. Music was playing in a browser during every run, so the live island indicators were active.

## Results

| Scenario | CPU before | CPU after | Footprint before | Footprint after | Wakeups/s before → after |
| --- | --- | --- | --- | --- | --- |
| Idle, island collapsed, no windows | 38.7 % | **0.23 %** | 96 MB | **20 MB** | 84 → 2.5 |
| Island open (Home player) | 38.5 % | **0.75 %** | 97 MB | **25 MB** | 84 → 3.7 |
| Workspace open, Overview | 35.1 % | **0.96 %** | 95 MB | **44 MB** | 79 → 2.5 |
| Workspace open, Clipboard page (4 images, 9 texts) | 22.8 % | **0.26 %** | 78 MB | **75 MB** | 87 → 3.1 |

Billed energy at idle fell from about 5.4 mJ/s to 0.016 mJ/s. The Now Playing helper (`/usr/bin/perl` hosting `NowPlayingHelper.dylib`) uses 0.1 % CPU and 4 MB.

- **Stability:** 45 island open/close cycles, 8 workspace and 6 Settings open/close cycles ran without crashes; `leaks` reports 0 leaks. Footprint settles around 70–87 MB after heavy use; the growth is framework and image caches, not leaks.
- **Startup:** the island is on screen about 310 ms after `open`.
- **Disk:** the app bundle is 10 MB (9.4 MB binary, 56 KB helper). Steady-state disk I/O is zero; the clipboard history is 3.2 MB for 13 entries.

## Causes and fixes

1. **Per-frame layout from animated indicators.** SwiftUI `TimelineView` level bars in the collapsed island and sidebar forced a full layout and size-fitting pass of the hosting view on every frame. They are now `LevelBars`, a Core Animation layer view animated by the render server.
2. **Hosting-view size measurement.** The island panel, workspace and Settings windows now set `NSHostingView.sizingOptions = []`; each window owns its frame, so SwiftUI no longer recomputes min/max content size on every update.
3. **Playback clock fan-out.** A 0.5 s progress timer published on `MediaController`, re-rendering every view that shows music. Progress now lives in `MediaProgress`, ticks at 1 s only while playing, and only time displays observe it.
4. **Second-by-second relative timestamps.** `Text(date, style: .relative)` in clipboard cards and notes re-laid out lists every second. `RelativeTimeText` refreshes every 30 s.
5. **Idle timers.** Removed the permanent 10 Hz hover timer. The island activity detector and System Activities model now react to published state, modifier events, `NWPathMonitor` and workspace volume notifications instead of waking at 2 Hz and every two seconds. Shelf retention uses one deadline timer only when an unpinned item can expire; the default keep-until-removed policy has no retention timer. Agenda polling is not installed until Calendar or Reminders has been connected. The focus countdown ticks only during a session.
6. **Clipboard persistence and images.** History writes are coalesced (0.4 s) and run on a utility queue. Large image and RTF bytes live in private, per-entry files under `clipboard-payloads-v1`; `clipboard-history.json` contains metadata, SHA-256 content identities and small previews. Existing inline archives migrate atomically: payload files are committed before the metadata archive is replaced, and corrupt archives remain read-only. Exact duplicate checks compare the byte count and persisted identity instead of rereading every matching archived payload on the main thread. Payloads are loaded only for copy/paste or legacy thumbnail generation. Persisted 480 px JPEG previews are force-decoded on the thumbnail queue before SwiftUI draws them. Clipboard-strip app and file icons are flattened to their display size and held in a 2 MB bounded cache rather than repeatedly requesting full multi-representation icons.
7. **Closed windows kept rendering state.** The workspace and Settings release their view trees on close.

## Clipboard follow-up measurements

The 16 September check used an isolated copy of the real 13-entry clipboard fixture and the packaged release, opening the Clipboard page through `SUPERNOTCH_DEBUG_PAGE=Clipboard`. RSS was sampled every 100 ms for ten seconds. This is a regression check, not directly interchangeable with the earlier `proc_pid_rusage` physical-footprint figures.

| Check | Result |
| --- | --- |
| Legacy archive input | 3.3 MB, including six inline payloads |
| First launch, migration + Clipboard page | 115,936 KiB peak RSS |
| Subsequent launch, Clipboard page | 102,112 KiB peak RSS; 99,808 KiB final RSS |
| Subsequent Clipboard launch, `vmmap` after 8 s | 42.8 MB physical footprint; 43.4 MB peak |
| Migrated metadata | 169,065 bytes |
| External payloads | 2,895,280 bytes across six files |
| Verified new-build launch, island collapsed | 21.0 MB physical footprint and peak |
| Verified new-build clipboard strip, first open | 44.4 MB physical footprint; 44.9 MB peak |
| Verified new-build clipboard strip, close/reopen | 48.9 MB physical footprint; 50.0 MB peak |

The previously documented approximately 320 MB Clipboard-page transient did not reproduce after migration in this fixture. The first migration launch stayed below 114 MiB RSS; the steady external-payload launch stayed below 100 MiB RSS and peaked at 43.4 MB physical footprint. The automated regression fixture independently verifies that a 2 MiB inline payload becomes metadata under 2 KiB, remains byte-identical, is not rewritten by a tag edit, is lazy after restart, and is removed with its entry.

A previous combined UI-automation run reported a 343 MB process peak without recording the executable path. A later check found that the custom URL scheme could activate an older `/Applications` copy while the packaged development build was also running; that older process reached a separate 306.3 MB peak. Those path-unverified figures are excluded from current-build results. After terminating every other copy, the exact packaged executable at `build/SuperNotch.app/Contents/MacOS/SuperNotch` peaked at 44.9 MB on first strip open and 50.0 MB after close/reopen with the 20-entry fixture. Migrated external image previews rendered successfully in the strip.

## Open items

- Measure wakeups again over the original 15–20 second `proc_pid_rusage` windows. The removed periodic sources are established in code, but no new wakeups-per-second figure is claimed here.
- Measurements cover one Mac and one display. External displays, Intel Macs, and long-duration energy tracking in Activity Monitor's Energy tab remain to be checked.

## Second optimization pass — 16 September 2026, evening

This pass measured the running app with the user's **live network graph and combined AI usage menu-bar modules enabled**. These settings differ from the earlier lightweight/default-menu-bar measurements above. Clipboard history contained 59–60 entries and the shelf contained five files. All measurements verified the executable path; an older installed copy briefly started by app discovery was immediately stopped and excluded. Another coding task rebuilt the app early in the session, so a separate fresh baseline was captured after coordination and its changes were preserved.

### Measurements

CPU is percentage of one logical core. Memory below is `ri_phys_footprint`, in **MiB**, not RSS or virtual address space. The sampler is now reproducible through `scripts/profile-process.c`. Its CPU conversion was checked against a busy single-thread process, which measured 99.1%.

| State | Window | Mean footprint | End footprint | Sampled peak | Average CPU |
| --- | --- | ---: | ---: | ---: | ---: |
| Fresh baseline, collapsed, live network graph | 15 s | 234.78 | 53.83 | 280.14 | 3.963% |
| Final release, collapsed, live network graph and music | 20 s | **30.29** | **30.31** | **30.36** | **1.079%** |
| Final release, collapsed after dashboard and Quick Look use | 20 s | 107.24 | 106.89 | 113.89 | 1.259% |
| Final release, full Performance dashboard | 15 s | 331.24 | 142.38 | 409.83 | 7.830% |

The fresh collapsed comparison reduces average footprint by **87.1%** and CPU by **72.8%**. The app was visibly collapsed before and after the final idle sample, with the live graph still enabled. These are local, short-duration observations, not cross-machine guarantees or a fixed memory ceiling. Media tracks and system load changed during the interactive session. An earlier dashboard implementation within this pass averaged 23.46% CPU; the final dashboard averaged 7.83%, but the active dashboard still has significant memory transients.

At task entry the existing process had a 539.8 MiB lifetime peak. That aged peak is **not** used as the baseline for the fresh comparison. The final process reached a 482.4 MiB lifetime peak during interactive testing. After closing the workspace it returned to approximately 107 MiB without a restart. A promise that the app always uses 30 MiB would therefore be incorrect.

### Changes

- Replaced the always-visible SwiftUI Canvas graph with native Core Graphics drawing. In the collapsed app, `vmmap` graphics allocations changed from about 230 MiB of IOAccelerator graphics regions (228 MiB resident in the baseline snapshot) to 80 KiB of regions / 16 KiB resident. The complete chart appearance, smoothing, scale, fills, and update cadence remain available.
- Extended native drawing to Activity history charts, per-core bars, rings, and segmented bars. Live gauges no longer run repeated interpolation animations. Native charts pass clicks through to the enclosing status button or scroll surface.
- Automatic Now Playing artwork now uses the asynchronous ImageIO downsampler too. Both player paths share a deterministic **4 MiB decoded-image cache**, with a 512-pixel maximum dimension and six-entry cap. Repeated metadata snapshots reuse images; cancelled/old-track decodes cannot replace current artwork. The largest player cover is 220 points, so 512 pixels covers its normal Retina size.
- Reduced the artwork network cache from 16 MiB to 2 MiB. Reused bounded, display-sized raster icons for app resource rows, player badges, and file-thumbnail fallbacks instead of retaining original multi-representation icons.
- Avoided unchanged media metadata publications in automatic and scripted playback; removed an unused system-monitor observation from the island. Script polling drains temporary Objective-C objects inside an autorelease pool.
- Fixed-size clipboard, palette, basket, and quick-ring hosts skip SwiftUI minimum/ideal/maximum size measurement. Hidden baskets and rings release their hosting trees and reconstruct correctly when reopened.
- Replaced the compact shelf's retained local event-monitor closure with scoped SwiftUI key handling. Selection → Space → Quick Look → Escape was verified live.

### Verification and remaining work

- **121 XCTest tests passed**, zero failures. New coverage includes exact decoded-cache budgeting and eviction, automatic image downsampling, metadata-only heartbeats, stale-result rejection after track changes/clear, bounded icon representations, native graph pixels, native ring pixels, and click pass-through.
- Final production build passed `-warnings-as-errors`; bundle signing and Info.plist validation passed. The generated and installed `/Applications/SuperNotch.app` binaries have matching SHA-256 hashes.
- Live checks: all workspace navigation groups; full clipboard search/empty state/image filtering and strip previews; file thumbnails; basket first open, dismiss and reopen; player artwork and play/pause; palette search and workspace execution; quick ring open/dismiss; Performance, Battery, Network and Volumes displays; menu-bar preview; workspace close/reopen; compact shelf Quick Look.
- Camera/microphone, new permission grants, charging-control changes, destructive clipboard operations, external sharing, and every export/input format were not manually exercised. Existing automated coverage remains the evidence for those covered non-UI paths. No claim of exhaustive hardware or permission validation is made.
- The latest leak scan after UI automation reports **8,432 bytes in 173 allocations**, predominantly NSArray/AXObserverCookie allocations. The earlier SwiftUI/local-event-monitor root cycle is absent from that scan. This is not a zero-leak claim; the small accessibility allocations and the full dashboard's remaining SwiftUI graphics transients warrant follow-up.
- Long-duration soak, external displays, Intel Macs, and sustained background energy measurements remain unverified.

Raw measurement summaries, final build/test logs and the leak report are in `build/performance-audit-2026-09-16/` (generated, ignored by Git). The prior installed app was backed up to `/tmp/supernotch-perf-pass/installed-before.app` for this session.

Reproduce a measurement:

```sh
clang -O2 scripts/profile-process.c -o /tmp/supernotch-profile
pgrep -x SuperNotch
/tmp/supernotch-profile <verified-pid> 20
```
