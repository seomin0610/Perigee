#!/bin/sh
# Also sets Info.plist MusicHapticsSupported, without which iOS ignores the app.
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make FINALPACKAGE=1
cp .theos/obj/TidalHaptics.dylib .
echo "==> $(pwd)/TidalHaptics.dylib"

if [ -n "$1" ]; then
	ipa="$1"
	shift
	cyan -w -i "$ipa" -o TIDAL_Haptics.ipa -f "$@" TidalHaptics.dylib --overwrite

	rm -rf .plistpatch && mkdir .plistpatch
	unzip -o -q TIDAL_Haptics.ipa 'Payload/*/Info.plist' -d .plistpatch
	python3 - <<'EOF'
import glob, plistlib
f = glob.glob('.plistpatch/Payload/*.app/Info.plist')[0]
p = plistlib.load(open(f, 'rb'))
p['MusicHapticsSupported'] = True
plistlib.dump(p, open(f, 'wb'), fmt=plistlib.FMT_BINARY)
EOF
	(cd .plistpatch && zip -q ../TIDAL_Haptics.ipa Payload/*/Info.plist)
	rm -rf .plistpatch
	echo "==> $(pwd)/TIDAL_Haptics.ipa"
fi
