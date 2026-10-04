# TidalOffline

Pick where TIDAL's offline downloads come from.

Tapping Download asks once per download (track, album, playlist):

- **v1**: `api.tidal.com/v1/tracks/{id}/playbackinfo`, the file itself without DRM
- **v2**: TIDAL's own `openapi.tidal.com/v2/trackManifests/{id}`, left untouched

With v1, the `trackManifests?usage=DOWNLOAD` request gets an answer built from playbackinfo, in the quality picked in TIDAL's download settings:

- `application/vnd.tidal.bts`: the manifest's file URL is downloaded directly into `Documents/TidalOffline/` (visible in the Files app) and handed to TIDAL's downloader as finished
- `application/dash+xml`: the init and FLAC segments are downloaded one after another and joined into one `Documents/TidalOffline/<uuid>.m4a`; TIDAL only reads the length from an HLS playlist made of the same segments

TIDAL's own iOS login only gets FairPlay-encrypted HLS from playbackinfo, so v1 needs its own login: **Settings > Offline Download > v1 login** opens TIDAL's PKCE login in a web view inside the app (the only login that gets lossless and Hi-Res files), keeps the token in the keychain and refreshes it. Without it v1 uses TIDAL's login and ends up on v2.

If playbackinfo fails or the file is encrypted, that track falls back to v2. The last choice applies to every download until the next one is picked.

## Build

    ./build.sh [<decrypted TIDAL.ipa> other.dylib ...]

Builds `TidalOffline.dylib`, and with an IPA also `TIDAL_Offline.ipa`. When sideloading, also inject TidalSideloadFix to stay logged in.
