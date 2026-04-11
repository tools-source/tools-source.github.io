# MusicTube (CarPlay + YouTube Login)

MusicTube is a SwiftUI iOS app starter that looks and behaves like a modern streaming music app, with:

- YouTube OAuth login (Google account)
- YouTube playlist/search metadata integration
- CarPlay-compatible browsing templates
- Ad-free app UI (no injected ads)

## Important compliance note

This project **does not include ad-bypass logic**. If you want ad-free playback of YouTube content, that depends on the user's YouTube account tier (for example, YouTube Premium) and YouTube's terms.

## Project structure

- `MusicTube/App`: app entrypoint and global state
- `MusicTube/Views`: home/search/player/login UI
- `MusicTube/Services`: YouTube auth/API and playback service
- `MusicTube/CarPlay`: CarPlay scene delegate and templates
- `MusicTube/Resources`: plist + entitlements templates

## Xcode setup

1. Open [MusicTube.xcodeproj](/Users/majdinagi/Documents/musicapp/MusicTube.xcodeproj).
2. Select your Apple development team in Signing & Capabilities if you want to run on a physical device.
3. In Google Cloud Console, create OAuth credentials for iOS/web as needed and update:
   - `MusicTube/Resources/Secrets.local.xcconfig`
4. Confirm the redirect URI in Google Cloud matches:
   - `com.codex.musictube:/oauth2redirect`
5. If you change the URL scheme, update both:
   - `YOUTUBE_URL_SCHEME`
   - `YOUTUBE_REDIRECT_URI`
6. If Apple does not automatically add the capability on your machine, enable:
   - `Background Modes` with `Audio, AirPlay, and Picture in Picture`
   - `CarPlay Audio App` only after Apple grants the CarPlay audio managed capability for your App ID

## Google OAuth setup

`Error 401: invalid_client` almost always means the app is still using the sample `YOUTUBE_CLIENT_ID` value or a client ID that does not exist in your Google Cloud project.

Before testing sign-in:

1. Create or open a Google Cloud project for this app.
2. Configure the OAuth consent screen.
3. Create a real OAuth client whose bundle identifier matches the app's bundle ID.
4. Leave `MusicTube/Resources/Secrets.xcconfig` as the checked-in template.
5. Copy your real values into `MusicTube/Resources/Secrets.local.xcconfig`.
6. Set `YOUTUBE_URL_SCHEME` to the iOS URL scheme shown for that client in Google Cloud.
7. Make sure the redirect URI used by the app matches the one configured for that client.
8. Rebuild after changing `Secrets.local.xcconfig` so the new values land in the app bundle.

## CarPlay entitlement note

The project now ships with an empty default entitlements file so it can sign on a normal Apple Developer account.

After Apple approves the CarPlay audio entitlement for your App ID, add this key back to `MusicTube/Resources/MusicTube.entitlements`:

`com.apple.developer.carplay-audio = true`

## Running

- Build and run on an iPhone simulator/device.
- CarPlay UI can be tested using the iOS Simulator's CarPlay external display mode.
- Privacy policy: [PRIVACY_POLICY.md](/Users/majdinagi/Documents/musicapp/PRIVACY_POLICY.md)

## Next recommended production steps

- Move token exchange to your backend and store refresh tokens server-side.
- Replace `MockLibraryService` with your licensed catalog source.
- Add offline downloads and queue persistence.
- Add voice intents for Siri + steering wheel controls.
