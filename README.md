Perigee for TIDAL
======================================

| Tweak | What it does |
|---|---|
| [Core](src/Core) | Settings hub: installed tweaks and versions, on/off, every tweak's settings, update notice |
| [LockLyrics](src/LockLyrics) | Current lyric line and animated artwork on the lock screen |
| [Meanings](src/Meanings) | Genius annotations for lyric lines |
| [Haptics](src/Haptics) | Apple Music Haptics for TIDAL |
| [KoreanSearch](src/KoreanSearch) | Find songs by their Korean titles |
| [LiquidTab](src/LiquidTab) | The iOS 26 system tab bar |
| [Privacy](src/Privacy) | Blocks TIDAL's trackers |
| [Offline](src/Offline) | Download offline tracks from v1 playbackinfo instead of v2 trackManifests |
| [SideloadFix](src/SideloadFix) | Stay logged in after sideloading (always include it) |
| [RadiantTidal](external/RadiantTidal) | Radiant Lyrics (submodule, GPL-3.0) |

Each tweak also works on its own.

## Build

Needs [Theos](https://theos.dev), [cyan](https://github.com/asdfzxcvbn/pyzule-rw) and `dpkg-deb`.

    git clone --recursive https://github.com/seomin0610/Perigee
    ./build-all.sh <decrypted TIDAL.ipa>

Writes `Perigee_TIDAL_<TIDAL version>_<version>.ipa` with every tweak in the right load order, and a `.deb` of the same name for rootless jailbreaks (no SideloadFix; files are prefixed `A_`, `B_`, ... to keep the load order). The version comes from `git describe --tags`. Haptics can't set `MusicHapticsSupported` from a deb, so it stays silent there.

