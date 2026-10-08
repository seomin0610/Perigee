# TidalKaraoke

Turns the vocals down so the song plays like a karaoke track. The lyrics come from Radiant Lyrics as usual.

- Apple's voice isolation (`AUSoundIsolation`) picks out the voice and it is taken out of the song
- where that can't run, the classic way: the part of the middle channel between 120 Hz and 8 kHz is dropped, so kick, bass and air stay

Needs TidalCore with Secondary Login (Advanced): only the DRM-free v1 stream can be processed. Works with TidalLoudness on or off.

`cc -O2 dsp_test.c -lm && ./a.out` checks the center cancel and the isolator subtraction.

## Build

    ./build.sh [<decrypted TIDAL.ipa>]
