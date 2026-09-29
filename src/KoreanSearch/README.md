# TidalKoreanSearch

Korean search for TIDAL iOS, an iOS port of the [KoreanSearch](https://github.com/seomin0610/luna-plugins/tree/master/plugins/KoreanSearch) luna plugin.

Search a song by its Korean title and the matching TIDAL track shows up at the top of the results. The Korean title is looked up on Apple Music, MusicBrainz and KOMCA to find the international title and ISRC.

- Only searches with complete Korean syllables are handled
- Added tracks are regular TIDAL rows: play, long-press menu and add to playlist all work
- Tracks already in the results are moved up, not duplicated
- Added tracks show the Korean title next to the original, e.g. "LILAC (라일락)"
- Results wait up to 8 s for the lookup; lookups are cached

## Settings

TidalCore draws them (`KSSettings` in `Tweak.m`); with no Core the defaults below apply.

| Key | Default | |
|---|---|---|
| `ks.itunes` | on | Apple Music (US/KR store titles) |
| `ks.musicbrainz` | on | MusicBrainz (ISRC) |
| `ks.komca` | on | KOMCA, only when the others missed |
| `ks.maxResults` | 8 | songs added to the results |

## Build

    ./build.sh [<decrypted TIDAL.ipa> other.dylib ...]

Builds `TidalKoreanSearch.dylib`, and with an IPA also `TIDAL_KoreanSearch.ipa`. When sideloading, also inject TidalSideloadFix to stay logged in.

Keep `KSResolve.m` and `KSMatch.m` in sync with the plugin's matching logic.
