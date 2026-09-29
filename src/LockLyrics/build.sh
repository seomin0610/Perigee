#!/bin/sh
# TidalLockLyrics goes first: it must hook setNowPlayingInfo: before RL/Meanings (see Tweak.m).
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make FINALPACKAGE=1
cp .theos/obj/TidalLockLyrics.dylib .
echo "==> $(pwd)/TidalLockLyrics.dylib"

if [ -n "$1" ]; then
	ipa="$1"
	shift
	cyan -w -i "$ipa" -o TIDAL_LockLyrics.ipa -f TidalLockLyrics.dylib "$@" --overwrite
	echo "==> $(pwd)/TIDAL_LockLyrics.ipa"
fi
