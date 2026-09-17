## Summary

Describe the user-visible outcome and why the change is needed.

## Validation

- [ ] `swift test`
- [ ] `swift build -c release -Xswiftc -warnings-as-errors`
- [ ] `./scripts/build-app.sh release`
- [ ] Relevant packaged-app behavior tested

List any hardware, permission, account, display or network scenarios that were not tested.

## Safety and compatibility

- [ ] Existing user data and original files are preserved.
- [ ] New persistence, permissions, network requests and privileged behavior are documented.
- [ ] No credentials, clipboard content, recordings, personal paths or generated bundles are included.
