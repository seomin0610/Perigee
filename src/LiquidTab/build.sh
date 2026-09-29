#!/bin/sh
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
[ -d "$THEOS" ] || { echo "Theos not found at $THEOS (set THEOS=...)" >&2; exit 1; }

make FINALPACKAGE=1
cp .theos/obj/TidalLiquidTab.dylib .
echo "==> $(pwd)/TidalLiquidTab.dylib"

if [ -n "$1" ]; then
	ipa="$1"
	shift
	cyan -w -i "$ipa" -o TIDAL_LiquidTab.ipa -f TidalLiquidTab.dylib "$@" --overwrite

	rm -rf .plistpatch && mkdir .plistpatch
	unzip -o -q TIDAL_LiquidTab.ipa 'Payload/*/Info.plist' -d .plistpatch
	python3 - <<'PY'
import glob, plistlib
f = glob.glob('.plistpatch/Payload/*.app/Info.plist')[0]
p = plistlib.load(open(f, 'rb'))
p['UIFileSharingEnabled'] = True
p['LSSupportsOpeningDocumentsInPlace'] = True
plistlib.dump(p, open(f, 'wb'), fmt=plistlib.FMT_BINARY)
PY
	(cd .plistpatch && zip -q ../TIDAL_LiquidTab.ipa Payload/*/Info.plist)
	rm -rf .plistpatch
	echo "==> $(pwd)/TIDAL_LiquidTab.ipa"
fi
