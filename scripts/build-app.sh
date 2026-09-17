#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
swift build -c "$configuration"
product_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/SuperNotch.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$product_dir/SuperNotch" "$app_dir/Contents/MacOS/SuperNotch"
# Charge limit helper. The app installs it as a root launch daemon only after the user
# turns on the charge limit and approves the administrator prompt.
cp "$product_dir/SuperNotchChargeHelper" "$app_dir/Contents/MacOS/SuperNotchChargeHelper"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"; fi
if [[ -d Resources/ProviderIcons ]]; then
    rm -rf "$app_dir/Contents/Resources/ProviderIcons"
    cp -R Resources/ProviderIcons "$app_dir/Contents/Resources/ProviderIcons"
fi
# System-wide Now Playing helper (loaded by /usr/bin/perl; see Helpers/NowPlaying).
mkdir -p "$app_dir/Contents/Resources/NowPlaying"
clang -fobjc-arc -O2 -dynamiclib -mmacosx-version-min=14.0 -framework Foundation -F /System/Library/PrivateFrameworks -framework MediaRemote \
    Helpers/NowPlaying/NowPlayingHelper.m -o "$app_dir/Contents/Resources/NowPlaying/NowPlayingHelper.dylib"
cp Helpers/NowPlaying/now-playing.pl "$app_dir/Contents/Resources/NowPlaying/now-playing.pl"
# Optional Spotify Dock helper. SuperNotch installs it only after an explicit
# user action in Music settings and keeps a full original Spotify backup.
mkdir -p "$app_dir/Contents/Resources/SpotifyDock"
clang -fobjc-arc -O2 -dynamiclib -mmacosx-version-min=14.0 -framework AppKit -framework Foundation \
    -install_name @rpath/SuperNotchSpotifyDock.dylib \
    Helpers/SpotifyDock/SuperNotchSpotifyDock.m -o "$app_dir/Contents/Resources/SpotifyDock/SuperNotchSpotifyDock.dylib"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
