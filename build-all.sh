#!/bin/sh
# Order = load order: TidalLockLyrics must hook setNowPlayingInfo: first, TidalHaptics after it.
set -e
cd "$(dirname "$0")"

export TT_BUILD="${TT_BUILD:-$(git describe --tags 2>/dev/null || echo dev)}"
export TT_BUILD="${TT_BUILD#v}"
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

# Rootless jailbreak deb. Substrate and ElleKit load DynamicLibraries alphabetically, so A_, B_, ... keep the
# order above (TidalCore strips the prefix). No SideloadFix: an App Store install isn't re-signed.
lib="$tmp/deb/var/jb/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$lib" "$tmp/deb/DEBIAN"
set -- A B C D E F G H I J K L M N O P
for d in $dylibs; do
	n=$(basename "$d" .dylib)
	[ "$n" = TidalSideloadFix ] && continue
	cp "$d" "$lib/${1}_$n.dylib"
	echo '{ Filter = { Bundles = ( "com.aspiro.TIDAL" ); }; }' >"$lib/${1}_$n.plist"
	shift
done
case $TT_BUILD in [0-9]*) v=$TT_BUILD ;; *) v=0~$TT_BUILD ;; esac
cat >"$tmp/deb/DEBIAN/control" <<EOF
Package: com.seomin0610.perigee
Name: Perigee
Version: $v
Architecture: iphoneos-arm64
Description: Tweaks for TIDAL
Maintainer: seomin0610
Author: seomin0610
Section: Tweaks
Depends: mobilesubstrate
EOF
deb="${out%.ipa}.deb"
dpkg-deb -Zxz --root-owner-group -b "$tmp/deb" "$deb" >/dev/null
rm -rf "$tmp"
echo "==> $out"
echo "==> $deb (version $TT_BUILD)"
