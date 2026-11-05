#!/bin/zsh
# Builds Lyps.app. SKIP_ADAPTER=1 leaves out the now-playing bridge, for testing the UI only.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Lyps
BIN=$(swift build -c release --show-bin-path)

APP=build/Lyps.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp "$BIN/Lyps" $APP/Contents/MacOS/Lyps
cp Resources/Info.plist $APP/Contents/Info.plist
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns

if [[ -z ${SKIP_ADAPTER:-} ]]; then
  scripts/build-adapter.sh
  cp -R .build/adapter/out/MediaRemoteAdapter.framework $APP/Contents/Frameworks/
  cp .build/adapter/src/bin/mediaremote-adapter.pl $APP/Contents/Resources/
  codesign --force --sign - $APP/Contents/Frameworks/MediaRemoteAdapter.framework
fi

# A free local signature, which Apple Silicon requires. Fine for this Mac; sharing needs notarizing.
codesign --force --sign - $APP
echo "$PWD/$APP"
