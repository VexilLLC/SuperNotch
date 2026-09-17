# Validation record

## Current automated baseline — 17 September 2026

- `swift test`: 122 tests passed with zero failures.
- `swift build -c release -Xswiftc -warnings-as-errors`: passed.
- `scripts/build-app.sh release`: passed.
- The generated app passed `plutil` validation and strict deep ad-hoc signature verification.
- The Alfred workflow archive built successfully, its plist validated, and its ZIP integrity check passed.
- A high-confidence scan found no common API-token or private-key patterns in the publishable tree.
- Charge-limit policy, helper installation-script generation and compatibility decoding are covered by unit tests. Real charging, discharge, sleep and MagSafe behavior remain hardware-dependent and are not established by these automated checks.

The entries below preserve the dated manual and performance history rather than replacing it.

## Initial validation — 15 September 2026

## Passed

- Production `swift build -c release` and app-bundle packaging.
- `codesign --verify --deep --strict` on the installed app (ad-hoc identity).
- Info.plist validation.
- Sixty-one XCTest regression tests, zero failures:
  - Clipboard concealment exclusion, pin retention, duplicate handling, persistence, copying.
  - Legacy clipboard history migration and source-app metadata round trips.
  - Inline clipboard payload migration to lazy per-entry files, byte-exact copy after restart, metadata-only writes that leave payload files untouched, orphan cleanup, and missing-payload clipboard preservation.
  - Command output, error status, output bound and cancellation.
  - Four image formats, dimensions, JPEG alpha flattening and source preservation.
  - Byte-exact 1.1 MB HTTP download, selected-route isolation and unsupported-method rejection.
  - Vault external-change conflicts and agent-schema validation.
  - Artwork rejects invalid/oversized data and downsamples a 2048 × 1024 fixture to 1024 × 512.
  - Four activity tests: silent baselines and changes, battery thresholds, shelf identity/focus completion, replacement/expiry and dismissal.
  - Shelf expiry boundaries, pinned retention, startup cleanup, deduplication and original-file preservation.
  - Shelf retention schedules no timer for the default keep-until-removed policy and installs a one-shot deadline only while an item can expire.
  - Thumbnail cancellation races, pre-start cancellation and bounded ImageIO raster decoding.
  - Five app-link parser/dispatcher tests covering supported routes and rejection of malformed or structured input.
  - Three CPU/storage tests covering elapsed deltas, nice time, reset/zero intervals, processor-count changes and storage bounds.
  - Four widget preference tests covering order/visibility persistence, last-widget protection, malformed numeric values and extreme reorder offsets.
  - Three basket collection tests covering legacy backup/migration, per-basket deduplication and clear, pin-preserving merges, captured destinations, active-selection persistence, limits, corrupt-file preservation and unchanged originals.
- Separate development harnesses: command process-group termination including TERM-resistant children, PDF rasterization, image resize, larger 2.1 MB local transfer, local server shutdown, audio/system enumeration, agent timestamps, live forecast decoding, and system observation lifecycle.

## Observed in the installed release UI

- Main workspace launches and renders.
- Tools navigation exposes the implemented groups.
- A project LICENSE file was added through the native chooser; the reference appeared in the shelf and survived restarting/installing the app. That reference remains as a useful local test item.
- Focus timer starts, switches to Pause, and resets. Test session was reset to 25 minutes.
- Native command input ran a harmless printf and displayed its output with exit status 0.
- Island expands with the file reference visible; Escape dismisses it after the responder fix.
- Floating clipboard opens with search focused. A real harmless test copy appeared in the strip, Pinned scope and full library; search clearing and keyboard browse were exercised. The unpinned “SuperNotch clipboard verification” test item remains in local history.
- Borderless basket displayed the persisted LICENSE reference. Escape dismissed the basket while leaving the island available.

- A real focus session showed its compact island activity strip and live countdown; the strip expired and the panel contracted automatically.

- Compact Notes retained a typed draft after collapse/reopen and saved it to the real local notes list. A later unfinished edit survived app termination/relaunch and saved back to the same note (count remained one). Full Notes and Full Agenda navigated the same existing workspace correctly. A harmless “SuperNotch widget verification” note remains.
- The original app-icon PNG renders as actual artwork in both the compact tray and basket. Selecting it and pressing Space opens native Quick Look; Escape returns to the island. The PNG and LICENSE references remain. The chooser opens and cancels cleanly; Go to Folder was exercised after focusing its file list.
- The dashboard and Tools → Activity → Performance show live CPU usage, user/system/idle breakdown, 16 logical processors and startup-volume storage. CPU progressed from collecting to a live reading on both surfaces; navigating between them retained the cached storage value.
- Widget reordering, hiding Agenda, selecting System and the Focus + Music Home arrangement survived a real app termination/relaunch. Command–1/2/3 switched all three island pages. Default widget order/visibility and Music + Focus were restored afterward.
- Multi-basket native check: created Review from the island, moved LICENSE from Main, saw it in the floating basket, relaunched with Review still selected, renamed it with a prefilled sheet, then merged it into Main. Both original reference IDs and files remained. The workspace showed the restored Main collection, and the legacy backup exists.
- Shelf retention visibly defaults to Keep until removed; production retention was not changed during testing.
- Compact Calendar and Reminders showed their explicit Connect states with no automatic permission prompt. Focus preset changed to 5 minutes and was restored to 25.

## Not established

- Full or pixel-identical parity with every reference workflow.
- Exhaustive global shortcut dispatch/conflict testing; menu and workspace buttons remain available.
- Permission-denial/regrant behavior for every protected API, and end-to-end operation of camera, microphone, Speech, Calendar, Reminders and Accessibility on all supported macOS releases.
- All Spotify/Music states, Bluetooth/AirPlay devices, multiple displays, sleep/wake and secure login sessions.
- Video export across a representative media fixture library, long dictation, very large PDFs, huge vaults, sustained server load, or cross-device LAN reachability.
- A successful live URLSession weather request in this environment; it timed out with a visible error. The endpoints returned data through curl and the real forecast response decoded successfully.
- Alfred workflow import/keyword execution and external URL launch. The workflow archive and plist validate; a browser-based local link test was blocked by browser security policy.
- Public notarization or execution of the repository's GitHub Actions workflow.

The artifact is a development release. Source and tests are in the repository; the ZIP and local app are generated by scripts/build-app.sh. No cloud deployment or GitHub publication was performed.

## Final clipboard update — 2026-09-15

- `swift test`: 40 tests passed, zero failures. Added strict color parsing tests and isolated clipboard tests for tag persistence, filtering, original-copy preservation, protected clearing, shared protection limits, repeat capture and corrupt-archive preservation.
- Production build completed and the installed `/Applications/SuperNotch.app` passed strict signature verification.
- Native verification: floating strip exposes tag controls; full library tag editor accepted and saved Design on the harmless verification clip. Selecting Design filtered the library to that clip, with a visible tag badge and intact card layout.
- Color parsing and copy preservation are covered by tests; the final color swatch was not visually verified with a live color clipboard item. No claim of complete parity or comprehensive permission testing is made.
- Feature expansion stopped at the user's request. Remaining gaps are recorded in FEATURE_PARITY.md.

## Performance hardening — 2026-09-16

- `swift test`: 61 tests passed, zero failures.
- `swift build -c release -Xswiftc -warnings-as-errors` passed; the clipboard persistence queue no longer emits the prior non-Sendable closure warning.
- `scripts/build-app.sh release` completed; the generated app passed strict deep signature verification and its Info.plist passed `plutil` validation.
- An isolated copy of the 3.3 MB, 13-entry clipboard archive migrated to 169,065 bytes of metadata plus 2,895,280 bytes in six private payload files. Byte-exact migration and copying are covered by tests.
- Sampled at 100 ms for ten seconds, the packaged release's Clipboard page peaked at 115,936 KiB RSS during migration and 102,112 KiB after migration, ending at 99,808 KiB. A separate steady migrated launch measured 42.8 MB physical footprint and a 43.4 MB peak after eight seconds. These results are scoped to the controlled fixture.
- A path-verified run of the newly packaged executable measured 21.0 MB physical footprint at collapsed launch, 44.9 MB peak on the first clipboard-strip open, and 50.0 MB peak after close/reopen with a 20-entry fixture. All external image previews rendered. An older `/Applications` copy was found handling the custom URL during an earlier measurement and was excluded.
- The island activity and System Activities periodic samplers were replaced with state and native-event subscriptions. Default shelf retention and disconnected agenda state install no timer. A fresh system wakeups-per-second run remains unclaimed.

## Second performance pass — 2026-09-16, evening

- 121 XCTest tests passed with zero failures; the final release build passed with warnings treated as errors.
- Final bundle signature and Info.plist validation passed. The installed app and generated app have identical executable hashes.
- Visually checked native history charts, per-core bars, rings and segmented bars in the Performance dashboard, and the live graph in Menu Bar settings.
- Exercised clipboard filtering, previews and empty state; basket first open and reconstruction after dismissal; media artwork/playback; command-palette search/navigation; quick-ring dismissal; all workspace tool destinations; Activity subpages; and workspace close/reopen.
- Verified compact shelf selection followed by Space opens native Quick Look for the existing icon PNG; Escape returns to the shelf and closes the island. Original files and shelf entries were retained.
- Final clean collapsed measurement: 30.29 MiB average physical footprint and 1.079% CPU over 20 seconds. After dashboard/Quick Look use and closing the workspace: 107.24 MiB average footprint, 1.259% CPU. Full Activity still has transient memory spikes, documented in PERFORMANCE.md.
- Final leak scan under UI automation was not clean: 8,432 bytes, predominantly accessibility observer/array allocations. The previously observed compact-shelf local-monitor retain cycle did not recur.
- Protected hardware, new permissions, charging-control actions, external sharing, all data formats, and long-duration reliability were not exhaustively exercised. See the measurement scope and remaining work in PERFORMANCE.md.
