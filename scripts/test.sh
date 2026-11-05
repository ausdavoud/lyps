#!/bin/zsh
# Without Xcode, `swift test` sometimes loses track of the testing macro plugin, so name it directly.
set -euo pipefail
cd "${0:A:h}/.."
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
