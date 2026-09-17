# Command palette extensions

SuperNotch loads local, declarative command manifests from:

```text
~/Library/Application Support/SuperNotch/Extensions/
```

Choose **Add Extension** in the command center, or open **Tools → Commands → Palette → Add Extension**, to create an extension without editing JSON. The in-app builder creates one command at a time and supports shell commands, URLs, and built-in SuperNotch actions.

For a multi-command extension, choose **Import Manifest…** on the same screen. You can also reveal the Extensions folder and manage manifests directly. A manifest is a UTF-8 JSON file no larger than 256 KiB. SuperNotch validates it before installation and accepts version 1 documents, up to 50 commands per extension and 200 loaded extension commands in total.

## Example

```json
{
  "version": 1,
  "id": "com.example.developer-tools",
  "name": "Developer Tools",
  "description": "Local project commands",
  "commands": [
    {
      "id": "open-dashboard",
      "name": "Open Local Dashboard",
      "subtitle": "Open localhost in the default browser",
      "symbol": "safari.fill",
      "keywords": ["web", "local"],
      "action": {
        "type": "url",
        "value": "http://localhost:3000"
      }
    },
    {
      "id": "run-tests",
      "name": "Run Project Tests",
      "subtitle": "Run the test suite and show its output",
      "symbol": "checkmark.circle.fill",
      "keywords": ["test", "swift"],
      "action": {
        "type": "shell",
        "value": "swift test",
        "workingDirectory": "~/Developer/MyProject"
      }
    },
    {
      "id": "clipboard",
      "name": "Clipboard History",
      "subtitle": "Open SuperNotch clipboard history",
      "symbol": "list.clipboard.fill",
      "keywords": ["copy", "paste"],
      "action": {
        "type": "builtin",
        "value": "clipboard"
      }
    }
  ]
}
```

## Actions

- `builtin`: invokes one of `clipboard`, `island`, `shelf`, `basket`, `notes`, `agenda`, `focus`, `workspace`, `settings`, `commandRunner`, `allFeatures`, `extensionManager`, or `extensionsFolder`.
- `url`: opens a URL through macOS. `file:`, `javascript:` and `data:` URLs are rejected.
- `shell`: runs a non-interactive zsh command through SuperNotch's bounded Command Runner. Output is shown in the workspace. `workingDirectory` is optional and must already exist.

Extension manifests are local code configuration. Review shell commands before installing a manifest from someone else. SuperNotch never runs an extension command automatically; the user must select it in the command palette.
