#!/bin/sh
# Order = load order: TidalLockLyrics must hook setNowPlayingInfo: first, TidalHaptics after it.
set -e
cd "$(dirname "$0")"

# The stamp is also TidalCore's build: tag the GitHub release v$TT_BUILD for its update notice
export TT_BUILD="${TT_BUILD:-$(date +%y%m%d-%H%M)}"
ipa="${1:-TIDAL Music_ HiFi Sound_2.215.0_decrypted.ipa}"
[ -f "$ipa" ] || { echo "IPA not found: $ipa" >&2; exit 1; }
tidal=$(python3 -c '
import plistlib, re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
f = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
print(plistlib.loads(z.read(f))["CFBundleShortVersionString"])
' "$ipa")
out="${2:-Perigee_TIDAL_${tidal}_$TT_BUILD.ipa}"
case $out in /*) ;; *) out="$(pwd)/$out" ;; esac

dylibs="
src/LockLyrics/TidalLockLyrics.dylib
src/SideloadFix/TidalSideloadFix.dylib
src/Privacy/TidalPrivacy.dylib
external/RadiantTidal/RadiantTidal.dylib
src/Meanings/TidalMeanings.dylib
src/KoreanSearch/TidalKoreanSearch.dylib
src/LiquidTab/TidalLiquidTab.dylib
src/Haptics/TidalHaptics.dylib
src/Core/TidalCore.dylib
"

for d in $dylibs; do ./"$(dirname "$d")"/build.sh; done

cyan -w -i "$ipa" -o "$out" -f $dylibs --overwrite

tmp=$(mktemp -d)
unzip -o -q "$out" 'Payload/*/Info.plist' -d "$tmp"
python3 - "$tmp" <<'PY'
import glob, plistlib, sys
f = glob.glob(sys.argv[1] + '/Payload/*.app/Info.plist')[0]
p = plistlib.load(open(f, 'rb'))
p['MusicHapticsSupported'] = True
p['UIFileSharingEnabled'] = True
p['LSSupportsOpeningDocumentsInPlace'] = True
plistlib.dump(p, open(f, 'wb'), fmt=plistlib.FMT_BINARY)
PY
(cd "$tmp" && zip -q "$out" Payload/*/Info.plist)
rm -rf "$tmp"
echo "==> $out (release tag v$TT_BUILD)"
