# TidalPrivacy

Blocks the services TIDAL iOS reports your usage to. Each has its own switch in TidalCore's settings:

| Switch | Service | Default |
|---|---|---|
| App monitoring | Datadog: screens, taps, requests, errors, crashes, Session Replay | Blocked |
| Session Replay only | Datadog's wireframe recording of the screen (shown when App monitoring is allowed) | Blocked |
| Crash reports | Firebase Crashlytics, which includes the list of loaded tweaks | Blocked |
| Marketing | Braze: sessions, events, push token, device info | Blocked |
| Usage and play reports | TIDAL's own event collector (`ec.tidal.com`, `et.tidal.com`) and offline play reports | Allowed |

TIDAL's own reports are allowed by default: they include the plays artists are paid from, and Recently Played and recommendations may depend on them. Turning that switch on asks first.

Switches apply right away. Each section's footer counts the requests blocked since TIDAL started.

## How it works

A URL protocol in every session's configuration fails requests to the blocked hosts with "cannot connect". The data never leaves the phone. The SDKs keep it on disk for a while and retry later. The widget and Siri extensions run in their own processes and aren't covered.

## Build

    ./build.sh [<decrypted TIDAL.ipa>]

Inject `TidalPrivacy.dylib`, or install `TIDAL_Privacy.ipa`.
