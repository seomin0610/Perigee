#!/bin/sh
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make clean >/dev/null # TT_BUILD isn't a file make can see change
make FINALPACKAGE=1
cp .theos/obj/TidalCore.dylib .
echo "==> $(pwd)/TidalCore.dylib"
