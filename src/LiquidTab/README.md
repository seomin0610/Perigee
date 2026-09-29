# TidalLiquidTab

Replaces TIDAL's glass tab bar with the real iOS 26 system tab bar (the same `UITabBarController` Apple Music uses).

Nothing is drawn by hand, so the selection lens, dragging across tabs, haptics, the separate search button, the mini player capsule and minimizing on scroll are all system behavior. TIDAL still does the tab switching; its own tab bar is only hidden. The mini player moves into the tab bar's accessory as-is.

Requires iOS 26. On older iOS it stays off and TIDAL keeps its own tab bar.

## Build

    ./build.sh <decrypted TIDAL.ipa> [other.dylib ...]

Writes `TIDAL_LiquidTab.ipa`. When sideloading, also inject TidalSideloadFix to stay logged in.
