# TidalCore

Settings hub for the TIDAL iOS tweaks. Adds one button to TIDAL's Settings that opens a single screen for all of them:

- Installed tweaks, each with an on/off switch (applies after restarting TIDAL; TidalSideloadFix can't be turned off)
- Every tweak's settings, drawn on one screen
- A link to Radiant Lyrics' own settings when it's installed
- An update notice when a newer release is on GitHub (checked at most once a day)

With TidalCore installed, the other tweaks leave their own buttons out of TIDAL's Settings. Without it, each tweak works on its own as before.

## Build

    ./build.sh

`../../build-all.sh` builds every tweak and injects them into one IPA, `Perigee_TIDAL_<TIDAL version>_<stamp>.ipa`. Publish it as GitHub release `v<stamp>` for the update notice to find it.
