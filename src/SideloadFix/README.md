# TidalSideloadFix

Keeps TIDAL working after sideloading. Include it in every sideloaded TIDAL IPA.

Re-signing changes the team ID, but TIDAL still uses its original keychain group from Info.plist, so every keychain write fails: you get logged out when the app closes and quality is stuck at Low (AAC). This tweak:

- Drops `kSecAttrAccessGroup` from TIDAL's `SecItem*` calls
- Provides a folder in `Library/AppGroup/<group>` when the app group container is unavailable

Log in once more after installing.

## Build

    ./build.sh [<decrypted TIDAL.ipa>]

Inject `TidalSideloadFix.dylib` with Feather or Sideloadly, or install `TIDAL_SideloadFix.ipa`.
