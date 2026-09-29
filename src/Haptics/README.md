# TidalHaptics

Music Haptics for TIDAL iOS: the iPhone taps along with the song, like in Apple Music.

Requires iOS 18+ and Settings > Accessibility > Music Haptics turned on.

## How it works

It uses Apple's own route, not audio analysis. The app declares `MusicHapticsSupported` in its Info.plist and names the playing song by ISRC in its now playing info. iOS then plays Apple's haptic track for that recording, synced to playback. The audio is never touched, so FairPlay, HLS and AirPlay don't matter. Songs without an Apple haptic track (not in the Apple Music catalog) stay silent.

ISRCs come from TIDAL's own API responses, matched to the playing song by title and length.

## Settings

Off by default. Turn it on in TidalCore's settings, or, without TidalCore, from the haptics button in TIDAL's Settings. The status line shows whether the current song has a haptic track.

## Build

    ./build.sh <decrypted TIDAL.ipa> [other.dylib ...]

Writes `TIDAL_Haptics.ipa` with `MusicHapticsSupported` set; a sideloader that rebuilds Info.plist must keep it. Load after TidalLockLyrics.
