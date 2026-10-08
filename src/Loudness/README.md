# TidalLoudness

Same volume from song to song, like VIBE's 음량 자동 조절. Each song gets one fixed volume; nothing changes inside a song.

TIDAL's Normalize volume sets one AVPlayer volume per song from the album's ReplayGain, so songs of one album keep their own loudness, and it can only turn songs down. This tweak:

- rewrites each `trackManifests` reply so the album gain the player reads is the track's own gain, and keeps Normalize volume on whatever TIDAL's own switch says
- with Secondary Login (TidalCore > Advanced), plays the DRM-free v1 stream instead and does the whole gain in an audio tap: quiet songs are raised too, and a 2 ms look-ahead limiter keeps peaks under -1 dBFS
- Volume-aware EQ, modelled on VIBE's (Gaudio ELEQ): the lower the phone volume, the more bass and treble the ear loses and the more is added back, plus up to +7 dB lift. Same volume table and step formula as VIBE's; the EQ curve is two shelves fitted to its measured response, not its table

The Level setting lowers the target by 4 or 8 dB.

`cc -O2 dsp_test.c -lm && ./a.out` checks the limiter and EQ.

## Build

    ./build.sh [<decrypted TIDAL.ipa>]
