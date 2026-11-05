#!/bin/zsh
# Builds the drag-to-install disk image for a GitHub release.
set -euo pipefail
cd "${0:A:h}/.."

scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG=build/Lyps-$VERSION.dmg

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/Lyps.app "$STAGE/Lyps.app"
ln -s /Applications "$STAGE/Applications"

rm -f $DMG
hdiutil create -quiet -volname "Lyps $VERSION" -srcfolder "$STAGE" -format UDZO -ov $DMG
hdiutil verify -quiet $DMG
echo "$PWD/$DMG"
shasum -a 256 $DMG
