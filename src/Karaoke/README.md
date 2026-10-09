# TidalKaraoke

Turns the vocals down so the song plays like a karaoke track. The lyrics come from Radiant Lyrics as usual.

- Apple's voice isolation (`AUSoundIsolation`) picks out the voice and it is taken out of the song
- where that can't run, the classic way: the part of the middle channel between 120 Hz and 8 kHz is dropped, so kick, bass and air stay

Scoring (like VIBE's): the singer's pitch is tracked on the isolated voice — worked out for the whole song ahead of playback from the downloaded file through a second voice isolator run offline, so the pitch bar shows what's coming — yours on the microphone (YIN, ~23 ms frames, a looser voicing threshold so soft singing counts, 5-frame median against consonant and breath blips, gaps of 2 frames filled), and every sung frame is graded Perfect / Cool / Good within 0.3 / 0.8 / 1.2 semitones (octave folded) against your one frame at your own lag, learnt from how the last 3 s of your singing follow the melody (within ±0.4 s, room for AirPods latency). The singer's pitch uses a looser voicing threshold (layered vocals), drops frames where the isolated voice is 14 dB+ under the mix (the band leaking through in intros), and only counts where it runs unbroken for ~140 ms (blips of instruments and breaths left in the isolated voice are dropped). Where two people sing, a dip at a multiple of the period is traced back to the real note, the other voice is kept as a second candidate (either part counts), and a frame whose pitch was unclear, or that comes within 0.25 s of a leap of 4+ semitones, isn't counted as Bad. Phrases are the singer's own voiced runs (not the lyrics' lines); rhythm compares where each sound starts (moving to a new note while singing on counts as a start, and singing on through one still gets half); held notes of 1 s+ count as long tones, and as vibrato when they swing 4-8 times a second. Score = pitch 70 + rhythm 15 + phrases 10 + up to 5 for vibrato and long tones. A live grade and a pitch bar (the singer's notes on 17 semitone lanes, your voice as a line) sit at the top of the screen; the score shows when the song ends.

Key: ±6 semitones through Apple's time-pitch unit (`NewTimePitch`), fed from a FIFO primed with 2048 frames since it may pull more than one tap buffer; the reference notes move with it. Earphones keep the music out of the microphone.

Needs TidalCore with Secondary Login (Advanced): only the DRM-free v1 stream can be processed. Works with TidalLoudness on or off.

`cc -O2 dsp_test.c -lm && ./a.out` checks the center cancel, the isolator subtraction, pitch tracking and grades.

## Build

    ./build.sh [<decrypted TIDAL.ipa>]
