# TidalKaraoke

Turns the vocals down so the song plays like a karaoke track. The lyrics come from Radiant Lyrics as usual.

- Apple's voice isolation (`AUSoundIsolation`) picks out the voice and it is taken out of the song
- where that can't run, the classic way: the part of the middle channel between 120 Hz and 8 kHz is dropped, so kick, bass and air stay

Scoring (like VIBE's): the singer's pitch is tracked on the isolated voice, yours on the microphone (YIN, ~23 ms frames), and every sung frame is graded Perfect / Cool / Good within 0.3 / 0.8 / 1.2 semitones (octave folded) against your one frame at your own lag, learnt from how the last 3 s of your singing follow the melody (within ±0.25 s). Phrases are the singer's own voiced runs (not the lyrics' lines); rhythm compares where each sound starts; held notes of 1 s+ count as long tones, and as vibrato when they swing 4-8 times a second. Score = pitch 70 + rhythm 15 + phrases 10 + up to 5 for vibrato and long tones. A live grade sits at the top of the screen; the score shows when the song ends. Earphones keep the music out of the microphone.

Needs TidalCore with Secondary Login (Advanced): only the DRM-free v1 stream can be processed. Works with TidalLoudness on or off.

`cc -O2 dsp_test.c -lm && ./a.out` checks the center cancel, the isolator subtraction, pitch tracking and grades.

## Build

    ./build.sh [<decrypted TIDAL.ipa>]
