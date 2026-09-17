# Contributing to SuperNotch

Thanks for helping improve SuperNotch. Focused bug fixes, tests, documentation and well-scoped features are welcome.

## Development setup

You need macOS 14 or later and Xcode with a Swift 6 toolchain.

```sh
swift test
./scripts/build-app.sh debug
open build/SuperNotch.app
```

Use the packaged app when testing protected APIs. The raw Swift executable does not have the bundle identity or usage descriptions required for permissions, Finder Services or app links.

## Before opening a pull request

1. Keep changes focused and explain the user-visible outcome.
2. Preserve existing user data and never modify or remove original shelf or processing inputs.
3. Keep blocking file, process and network work off the main actor.
4. Document new network requests, persistent storage, permissions and privileged behavior.
5. Add regression coverage where the behavior can run without private accounts or hardware.
6. Run:

   ```sh
   swift test
   swift build -c release -Xswiftc -warnings-as-errors
   ./scripts/build-app.sh release
   plutil -lint build/SuperNotch.app/Contents/Info.plist
   codesign --verify --deep --strict build/SuperNotch.app
   ```

Hardware-, account- and permission-dependent changes should include the tested Mac model, macOS version, permission state and any untested boundaries in the pull request.

## High-risk areas

Changes involving the charge helper, AppleSMC, private MediaRemote APIs, Spotify bundle modification, clipboard persistence, local HTTP sharing or shell execution need a clear threat and failure analysis. Privileged operations must be explicit, narrowly scoped, reversible and safe when interrupted.

Never commit credentials, real clipboard archives, recordings, personal vaults, signing identities or generated app bundles.

## Style and commits

Follow the surrounding Swift style and prefer native frameworks over new dependencies. Commit subjects use Conventional Commits, for example:

```text
fix(clipboard): preserve tags when recapturing content
feat(battery): add charge helper status details
docs: clarify local sharing boundaries
```

By contributing, you agree that your contribution is licensed under the repository's MIT License and to follow the Code of Conduct.
