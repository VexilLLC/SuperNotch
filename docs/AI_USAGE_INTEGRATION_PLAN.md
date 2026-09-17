# AI usage tracking integration plan

16 September 2026.

## Outcome

Add one native **AI Usage** widget to SuperNotch that answers two questions at a glance:

1. Which subscription is closest to its limit?
2. When does that limit reset?

The first provider set is Codex, Claude, OpenCode Go/Zen, Grok, Cursor, Antigravity and Muse Code. The feature should work without requiring OpenUsage to be installed, should not ask the user to paste credentials already stored by a provider's own app or CLI, and should not make the collapsed notch permanently noisy.

## Research baseline

The implementation study used [robinebers/openusage](https://github.com/robinebers/openusage) at commit `86df736eb3099cd3f61806bf6c30e4baf967b8f9` (15 September 2026). OpenUsage is MIT licensed.

The useful ideas to carry into SuperNotch are:

- one adapter per provider, split into credential discovery, network/local client and response mapper;
- a small normalized metric vocabulary instead of provider-specific UI;
- five-minute cache freshness with stale-while-revalidate behavior;
- concurrent provider refreshes, per-provider in-flight guards and a hard timeout;
- last-good data stays visible when a refresh fails;
- cheap local credential detection enables only tools that are actually installed;
- local logs are scanned incrementally and never uploaded;
- bounded values retain raw usage, limit, reset time and window duration so the UI can format them consistently.

SuperNotch should adapt those ideas, not import OpenUsage as a runtime dependency. OpenUsage targets macOS 15 and Swift 6.2, exposes executables rather than a supported library product, and includes update/analytics/hotkey dependencies that SuperNotch does not need. SuperNotch currently targets macOS 14, Swift 6 in Swift 5 language mode, and has no package dependencies.

If substantial OpenUsage source or provider SVGs are reused, add a `NOTICE` entry preserving its MIT copyright and licence notice.

## Provider coverage

| Provider | Live source | Local history source | First useful metrics | Delivery note |
| --- | --- | --- | --- | --- |
| Codex | `chatgpt.com/backend-api/wham/usage` with the existing Codex OAuth login | Codex session rollouts, plus eligible OpenCode/pi sessions later | Session, Weekly, credits, Today | Proven path; ship first. Respect `CODEX_HOME`. |
| Claude | Anthropic OAuth usage/profile endpoints using the existing Claude Code login | Claude project session JSONL | Session, Weekly, model limit, extra usage, Today | Start with the active Claude Code account. Multi-account/Desktop decryption is a later hardening pass. Respect `CLAUDE_CONFIG_DIR`. |
| OpenCode | OpenCode Go usage endpoint with the local `opencode-go` key | Read-only OpenCode SQLite databases | Go Session, Weekly, Monthly; Go + Zen Today | Go limits are account-wide; Zen is local spend rather than a quota. Respect XDG/OpenCode data paths. |
| Grok | Grok CLI billing/settings endpoints with its existing login | Completed Grok CLI sessions | Weekly, extra-usage state, Today | Refresh an expired login only through the provider-compatible flow. Respect `GROK_HOME`. |
| Cursor | Cursor dashboard/usage endpoints using Cursor's local state and keychain login | Cursor usage CSV export | Total Usage, Cursor Models, Other Models, Grok Bot, on-demand | Highest integration risk: several optional endpoints and plan-dependent response shapes. |
| Antigravity | Running local language server first; Google Cloud Code fallback | Antigravity conversation databases | Gemini Session/Weekly, non-Gemini Session/Weekly | Highest reverse-engineering risk. Treat missing weekly data as partial success. |
| Muse Code | No stable subscription-usage endpoint is currently documented | `~/.local/share/muse/sessions/.../session.jsonl`, when present | Today tokens/spend estimate, recent activity | Experimental. Detect `~/.config/muse/auth.json`, but never invent a quota percentage. Add live Session/Weekly only after a stable source is verified. |

Provider support must be capability-based. A provider can legitimately expose only local history, only live quota, or both. The UI should label local cost as **Estimated** and should distinguish **Not connected**, **Quota unavailable**, **Stale** and **Refresh failed**.

## Native data architecture

Create a focused `Sources/SuperNotch/AIUsage/` module boundary within the existing executable target.

### Core model

Suggested files:

- `AIUsageModels.swift`
- `AIUsageProvider.swift`
- `AIUsageStore.swift`
- `AIUsageSnapshotCache.swift`
- `AIUsageFormatting.swift`
- `AIUsagePacing.swift`

The UI-facing model should stay small:

```swift
enum AIUsageMetricValue: Codable, Equatable, Sendable {
    case quota(used: Double, limit: Double, unit: Unit, resetsAt: Date?, window: TimeInterval?)
    case values([MeasuredValue])
    case status(text: String, severity: Severity)
}

struct AIProviderSnapshot: Codable, Equatable, Sendable {
    let providerID: AIProviderID
    let displayName: String
    let plan: String?
    let metrics: [AIUsageMetric]
    let fetchedAt: Date
    let warning: String?
}
```

Keep raw numbers in the snapshot. Never persist display strings such as `42% left` or `Resets in 3h`; those belong at the view edge so locale, used/remaining mode and countdowns remain live.

### Provider contract

Each adapter should conform to one contract:

```swift
protocol AIUsageProvider: Sendable {
    var id: AIProviderID { get }
    func detect() async -> AIProviderDetection
    func refresh() async -> AIProviderSnapshot
}
```

Provider folders should contain an auth reader, client/scanner, mapper and focused tests. Credential discovery must be local-only. Network requests begin only for providers the user has enabled.

### Store and refresh lifecycle

`AIUsageStore.shared` owns all UI state and scheduling:

- load the last-good cache immediately on launch;
- refresh enabled providers concurrently;
- use a five-minute success TTL and a short failure backoff;
- prevent duplicate refreshes for the same provider;
- cap each provider refresh at 120 seconds;
- preserve the previous good snapshot when a refresh fails;
- publish per-provider `refreshing`, `stale`, `warning` and `error` state;
- refresh on demand from the widget and Settings;
- tick reset labels locally every 30 seconds without another network request;
- pause the periodic network loop when AI Usage is disabled and no quota alert is enabled.

Cache only normalized snapshots under `~/Library/Application Support/SuperNotch/ai-usage-snapshots-v1.json`. Write atomically with owner-only permissions. Credentials, raw API bodies, prompts, conversation text and model output never enter this cache.

Local history scanners should cache parsed accounting records separately by path, file size, modification date and parser version. Read JSONL incrementally, bound individual record size, open SQLite databases read-only and deduplicate copied/forked/subagent accounting events before summing.

### Credential handling

- Read existing provider files and Keychain items; do not add a generic "paste token" field for these providers.
- Never log a token, auth header, raw keychain value, full provider response or source log line.
- Do not silently substitute an API key for a subscription login; API billing and subscription limits are different products.
- When a provider requires token rotation, update only its original store, atomically, and only if it still contains the credential that began the refresh. A newer login always wins.
- Claude Desktop decryption and Antigravity language-server access should be isolated behind explicit adapters because they may trigger permissions or change across provider releases.

## Notch design

### Expanded island: one widget, two levels

Append `AI Usage` as `IslandWidgetID` raw value `4`, preserving the existing persisted IDs.

The widget opens on an **Overview** rather than selecting an arbitrary provider. Its 480 × 238 pt island page stays within the current geometry.

**Overview content**

- Header: `AI Usage`, last-updated age and a compact refresh button.
- Provider rail: real provider marks in a horizontally scrollable row. A small status dot communicates healthy, warning, critical, stale or unavailable. Do not put seven full text tabs across the width.
- Attention list: the three most important current limits, sorted by severity and then remaining percentage. Each row shows provider, metric, remaining value, a thin progress rail and reset countdown.
- Quiet footer: `4 more providers` or the most relevant connection problem. No total-spend donut in the notch; it consumes too much of the compact surface.

Selecting a provider mark opens **Provider detail** in the same widget:

- brand mark, provider name and optional plan;
- up to three primary quota rows, ordered Session → Weekly → provider-specific pool;
- one compact local-spend line when available;
- warning/stale state beside the header, not in place of last-good values;
- back-to-overview control and refresh action.

Quota rows default to **remaining**, because that answers the user's decision fastest. Color reflects urgency, not brand:

- accent/blue: healthy;
- amber: 20% or less remaining, or projected to finish with little headroom;
- red: 10% or less remaining, exhausted, or projected to run out before reset;
- grey: unavailable/stale with no last-good value.

Provider identity lives in the mark and label. Progress-bar color must remain semantic so users do not have to learn seven unrelated color scales.

### Collapsed notch: optional single pin

Do not render every provider in the collapsed notch. Add an opt-in **Pinned usage** setting:

- left ear: selected provider mark;
- right ear: a single compact remaining value such as `42%`;
- click opens Widgets → AI Usage → that provider;
- active Now Playing or Focus keeps the existing priority and temporarily hides the usage pin;
- if the pinned metric has no data, hide the ears instead of showing a placeholder.

This brings usage into the notch without turning the menu bar into a ticker.

### Alerts

Reuse `IslandActivityController` for threshold transitions:

- `Claude weekly · 9% left`
- `Codex session reset · 100% available`
- `Cursor usage unavailable`

Only emit on a meaningful edge: crossing 20%, crossing 10%, reaching the limit, recovering after reset or a fresh provider failure after previously working. Establishing the startup baseline must be silent, and identical states must not repeat every five minutes.

### Settings

Add a dedicated **AI Usage** Settings section rather than overloading the current Widgets page.

The page should contain:

1. **Providers** — detected state, enable switch, last refresh/error and a manual refresh action.
2. **Notch pin** — provider and metric picker, default Off.
3. **Display** — Remaining/Used and Countdown/Reset time.
4. **Alerts** — Almost out (10%) and Reset recovered, both off by default.
5. **Privacy** — concise source disclosure: which local credential/log is read and which provider host receives a request.

The existing Widgets section still controls whether the whole AI Usage widget appears and where it sits in the widget order.

### Accessibility and motion

- Every percentage must have an accessibility label containing provider, metric, used/remaining state and reset time.
- Do not rely on color alone; pair warning colors with an icon or text.
- Use monospaced digits for percentages and countdowns.
- Respect Reduce Motion for overview/detail transitions and progress changes.
- Keep controls at least 24 pt in the compact island and expose complete labels to VoiceOver.

## Implementation sequence

### Phase 1 — foundation and trustworthy MVP

1. Add the normalized models, provider protocol, snapshot cache and refresh store.
2. Implement local detection and enablement persistence.
3. Implement Codex, Claude and OpenCode adapters with live quota; add local history only after the quota mapping is stable.
4. Add `AI Usage` to `IslandWidgetID`, the overview/detail widget and the AI Usage Settings page.
5. Add manual refresh, stale indicators and a default-off collapsed pin.

Exit criteria: cached values paint instantly; live data refreshes without blocking the main actor; a provider failure preserves last-good data; the widget handles zero, one and many detected providers; no secret appears in logs or cache.

### Phase 2 — remaining proven providers

1. Add Grok.
2. Add Cursor with optional endpoints treated as partial success.
3. Add Antigravity with language-server-first and Cloud Code fallback.
4. Add incremental local history for supported providers and the compact Today line.
5. Add deduplicated threshold/reset activity strips.

Exit criteria: one slow provider does not delay others; missing optional metrics do not fail an otherwise useful snapshot; every local scanner is bounded and read-only.

### Phase 3 — Muse and polish

1. Detect Muse Code and parse its local session accounting into Today/Last 30 Days where the log schema supplies trustworthy token usage.
2. Show `Quota unavailable` until Meta exposes a stable subscription allowance source; do not derive quota from guessed plan sizes.
3. Add live Muse limits only behind a fixture-tested adapter once the source and reset semantics are verified.
4. Add the larger workspace AI Usage page for 30-day trends/model breakdowns if the compact widget proves useful.

## Tests and validation

Add test groups for:

- metric normalization, clamping and remaining/used formatting;
- reset countdown boundaries and pace severity;
- cache age, atomic replacement, stale-while-revalidate and corrupt-cache recovery;
- provider detection without network access;
- auth precedence and token redaction;
- fixture-based response mapping for every provider;
- 401/403 refresh-and-retry paths without duplicate requests;
- JSONL oversized-record handling and copied-session deduplication;
- OpenCode read-only SQLite aggregation;
- widget preference migration with new raw value `4`;
- severity sorting, provider selection and no-data/partial/stale/error UI states;
- collapsed-pin priority against Now Playing and Focus;
- activity-alert edge deduplication.

Native validation should cover a notched Mac, a notchless/external display, Reduce Motion, VoiceOver, a locked Keychain, offline mode, provider logout/account swap and a provider refresh that hangs until timeout.

## Deliberate non-goals for the first release

- Requiring OpenUsage to be installed or reading its UI.
- Running a loopback HTTP server.
- Syncing usage through iCloud.
- Claiming/spending Codex reset credits from SuperNotch.
- Asking for arbitrary API keys.
- Showing a total-spend chart in the compact notch.
- Guessing Muse subscription limits.

These can be revisited after the read-only, privacy-preserving usage surface is stable.
