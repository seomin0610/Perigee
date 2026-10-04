#!/bin/sh
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make FINALPACKAGE=1
cp .theos/obj/TidalOffline.dylib .
echo "==> $(pwd)/TidalOffline.dylib"

if [ -n "$1" ]; then
	ipa="$1"
	shift
	cyan -w -i "$ipa" -o TIDAL_Offline.ipa -f TidalOffline.dylib "$@" --overwrite
	echo "==> $(pwd)/TIDAL_Offline.ipa"
fi
