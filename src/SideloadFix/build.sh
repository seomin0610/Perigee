#!/bin/sh
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make FINALPACKAGE=1
cp .theos/obj/TidalSideloadFix.dylib .
echo "==> $(pwd)/TidalSideloadFix.dylib"

if [ -n "$1" ]; then
	cyan -w -i "$1" -o TIDAL_SideloadFix.ipa -f TidalSideloadFix.dylib --overwrite
	echo "==> $(pwd)/TIDAL_SideloadFix.ipa"
fi
