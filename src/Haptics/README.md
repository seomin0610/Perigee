# TidalHaptics

Music Haptics for TIDAL iOS: the iPhone taps along with the song.

## Song analysis (default)

TIDAL streams FairPlay HLS, which can't be tapped, so the song's audio is fetched separately: v1 playbackinfo at LOW quality with Perigee's v1 login (TidalCore, Settings > Advanced) returns a plain AAC file. It is decoded to mono 22.05 kHz and analysed once (`Analyze.c`): a low band (under 150 Hz) and a mid band (around 2.5 kHz) are filtered, their onsets picked as kick and snare taps, and the low band's loudness becomes a rumble. Results are cached per track in Caches/TidalHaptics. Core Haptics plays them in sync with TIDAL's AVPlayer.

Follows: Everything (taps and rumble), Beat (taps only) or Bass (kick taps and rumble). Strength 50 to 200%. Plays only while TIDAL is on screen (Core Haptics stops in the background).

Self-check of the analyzer: `cc -O2 analyze_test.c -lm && ./a.out`

## Apple haptic tracks

Info.plist `MusicHapticsSupported` plus the song's ISRC in the now playing info: iOS plays Apple's own haptic track (Apple Music catalog songs only, iOS 18+, Settings > Accessibility > Music Haptics on). Works in the background.

ISRCs and track ids come from TIDAL's own API responses, matched to the playing song by title and length.

## Build

    ./build.sh <decrypted TIDAL.ipa> [other.dylib ...]

Writes `TIDAL_Haptics.ipa` with `MusicHapticsSupported` set; a sideloader that rebuilds Info.plist must keep it. Load after TidalLockLyrics. Song analysis needs TidalCore for the v1 login; without TidalCore it uses Apple haptic tracks.
