# Alfred integration

SuperNotch exposes a deliberately small custom URL scheme for local Alfred
actions. The app handles only these exact routes:

| Alfred keyword | URL | Result |
| --- | --- | --- |
| `sn-island` | `supernotch://island` | Expand the island |
| `sn-clipboard` | `supernotch://clipboard` | Open clipboard history |
| `sn-shelf` | `supernotch://shelf` | Open the file shelf workspace |
| `sn-basket` | `supernotch://basket` | Open the floating basket |
| `sn-notes` | `supernotch://notes` | Open the quick notes widget |
| `sn-agenda` | `supernotch://agenda` | Open the agenda widget |
| `sn-focus` | `supernotch://focus` | Open focus controls |
| `sn-player` | `supernotch://player` | Show the app that is playing music |

The packaged app registers the `supernotch` URL scheme. Incoming actions are queued during cold launch until its panels and stores are ready.

The dispatcher is intentionally action-only. It rejects unknown routes,
queries, fragments, credentials, ports, and extra path components. It never
executes a shell command, opens a caller-provided file path, or performs a
network request as a result of a URL.

## Installing the workflow

1. Build and install the packaged SuperNotch app.
2. From this repository, run:

   ```sh
   integrations/alfred/build-workflow.sh
   ```

3. Double-click the generated `integrations/alfred/SuperNotch.alfredworkflow`
   file and confirm the import in Alfred.
4. Invoke a keyword such as `sn-shelf` and press Return.

The workflow uses Alfred's native **Open URL** actions. It does not include an
AppleScript, shell action, network call, or path argument. The source plist is
at [`integrations/alfred/info.plist`](../integrations/alfred/info.plist), and
the packaging helper validates it with `plutil` before creating the standard
`.alfredworkflow` zip archive.

The workflow schema follows Alfred's documented Open URL action and keyword
input objects:

- [Keyword input](https://www.alfredapp.com/help/workflows/inputs/keyword/)
- [Open URL action](https://www.alfredapp.com/help/workflows/actions/open-url/)
- [Installing workflows](https://www.alfredapp.com/help/workflows/)

## Validation boundary

Parser and dispatcher unit tests, plist validation and archive structure checks pass. Import and keyword execution in Alfred, and macOS launching the app from an external URL, have not been verified interactively. A browser-based local test page was blocked by the browser security policy.
