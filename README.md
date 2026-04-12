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
3. In Google Cloud Console, create OAuth credentials for iOS and update:
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
3. Create a real iOS OAuth client whose bundle identifier matches the app's bundle ID.
4. Leave `MusicTube/Resources/Secrets.xcconfig` as the checked-in template.
5. Copy your real values into `MusicTube/Resources/Secrets.local.xcconfig`.
6. Set `YOUTUBE_URL_SCHEME` to the iOS URL scheme shown for that client in Google Cloud.
7. Make sure the redirect URI used by the app matches the one configured for that client.
8. Rebuild after changing `Secrets.local.xcconfig` so the new values land in the app bundle.
9. Do not ship a Google OAuth client secret inside the app bundle. This project uses PKCE for the native iPhone flow.

## CarPlay entitlement note

The project now ships with an empty default entitlements file so it can sign on a normal Apple Developer account.

After Apple approves the CarPlay audio entitlement for your App ID, add this key back to `MusicTube/Resources/MusicTube.entitlements`:

`com.apple.developer.carplay-audio = true`

## Running

- Build and run on an iPhone simulator/device.
- CarPlay UI can be tested using the iOS Simulator's CarPlay external display mode.
- Production site: [index.html](/Users/majdinagi/Documents/musicapp/index.html)
- Privacy policy: [PRIVACY_POLICY.html](/Users/majdinagi/Documents/musicapp/PRIVACY_POLICY.html)
- Terms of service: [TERMS.html](/Users/majdinagi/Documents/musicapp/TERMS.html)
- Support page: [SUPPORT.html](/Users/majdinagi/Documents/musicapp/SUPPORT.html)

## Next recommended production steps

- Verify the live public site domain in Google Search Console before requesting Google Auth Platform branding review. For the current deployment, verify `https://music--musicapp-55a60.us-east4.hosted.app/` as a URL-prefix property using the same Google account that owns the Cloud project.
- Keep the app domain links distinct and publicly reachable on the same verified domain:
  - home: `https://music--musicapp-55a60.us-east4.hosted.app/`
  - privacy: `https://music--musicapp-55a60.us-east4.hosted.app/PRIVACY_POLICY.html`
  - terms: `https://music--musicapp-55a60.us-east4.hosted.app/TERMS.html`
- Publish branding only after the homepage, privacy policy, and terms links are live and returning their own pages without redirecting back to the home page.
- Move token exchange to your backend and store refresh tokens server-side.
- Add offline downloads and queue persistence.
- Add voice intents for Siri + steering wheel controls.
