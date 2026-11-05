#!/bin/zsh
# Builds the now-playing bridge (ungive/mediaremote-adapter, BSD-3).
# Pinned, so an upstream change can't alter what ships.
set -euo pipefail
cd "${0:A:h}/.."

TAG=v0.7.7
SRC=.build/adapter/src

if [[ ! -d $SRC/.git ]] || [[ $(git -C $SRC describe --tags --exact-match 2>/dev/null) != $TAG ]]; then
  rm -rf .build/adapter
  git clone --quiet --depth 1 --branch $TAG https://github.com/ungive/mediaremote-adapter.git $SRC
fi
cmake -S $SRC -B .build/adapter/out -DCMAKE_BUILD_TYPE=Release -Wno-dev >/dev/null
cmake --build .build/adapter/out --parallel >/dev/null
