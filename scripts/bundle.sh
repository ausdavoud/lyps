#!/bin/zsh
# Builds Lyps.app for Apple Silicon and Intel. SKIP_ADAPTER=1 leaves out the now-playing bridge,
# for testing the UI only.
set -euo pipefail
cd "${0:A:h}/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product Lyps $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=build/Lyps.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp "$BIN/Lyps" $APP/Contents/MacOS/Lyps
cp Resources/Info.plist $APP/Contents/Info.plist
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp LICENSE $APP/Contents/Resources/LICENSE

if [[ -z ${SKIP_ADAPTER:-} ]]; then
  scripts/build-adapter.sh
  cp -R .build/adapter/out/MediaRemoteAdapter.framework $APP/Contents/Frameworks/
  cp .build/adapter/src/bin/mediaremote-adapter.pl $APP/Contents/Resources/
  cp .build/adapter/src/LICENSE $APP/Contents/Resources/mediaremote-adapter-LICENSE
  codesign --force --sign - $APP/Contents/Frameworks/MediaRemoteAdapter.framework
fi

# A free local signature, which Apple Silicon requires. Fine for this Mac; downloads aren't notarized.
codesign --force --sign - $APP
echo "$PWD/$APP"
