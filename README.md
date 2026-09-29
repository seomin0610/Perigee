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
| [SideloadFix](src/SideloadFix) | Stay logged in after sideloading (always include it) |
| [RadiantTidal](external/RadiantTidal) | Radiant Lyrics (submodule, GPL-3.0) |

Each tweak also works on its own.

## Build

Needs [Theos](https://theos.dev) and [cyan](https://github.com/asdfzxcvbn/pyzule-rw).

    git clone --recursive https://github.com/seomin0610/Perigee
    ./build-all.sh <decrypted TIDAL.ipa>

Writes `Perigee_TIDAL_<TIDAL version>_<stamp>.ipa` with every tweak in the right load order. Publish it as GitHub release `v<stamp>` for TidalCore's update notice.
