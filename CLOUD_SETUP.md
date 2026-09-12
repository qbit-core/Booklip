# Cloud Login Setup (OneDrive & Google Drive)

The app signs in with **your** Microsoft / Google account using OAuth 2.0.
For that to work you must register an app on each platform (free) and paste
the resulting IDs into `Booklip/Cloud/CloudConfig.swift`.

This is a one-time setup. Takes ~15 minutes total.

---

## 1. OneDrive (Microsoft)

### Register the app
1. Open **https://portal.azure.com** → sign in
2. Search **"App registrations"** → **+ New registration**
3. **Name:** `Booklip`
4. **Supported account types:** *Personal Microsoft accounts only*
   (or "Accounts in any org directory and personal" if you also want work accounts)
5. **Redirect URI:**
   - Platform dropdown → **Mobile and desktop applications**
   - Value: `booklip://auth/onedrive`
6. Click **Register**

### Copy the Client ID
- On the app's **Overview** page, copy **Application (client) ID**
- Paste into `CloudConfig.oneDriveClientID`

### Add permissions
1. Left sidebar → **API permissions** → **+ Add a permission**
2. **Microsoft Graph** → **Delegated permissions**
3. Add: **Files.Read** and **offline_access**
4. (Personal accounts don't need admin consent.)

### Enable public client flow
1. Left sidebar → **Authentication**
2. Scroll to **Advanced settings** → **Allow public client flows** → **Yes** → Save

---

## 2. Google Drive

### Create a project & enable the API
1. Open **https://console.cloud.google.com**
2. Top bar → **Select a project** → **New Project** → name it `Booklip` → Create
3. **APIs & Services → Library** → search **Google Drive API** → **Enable**

### Configure the consent screen
1. **APIs & Services → OAuth consent screen**
2. User type: **External** → Create
3. Fill app name, your email; **Save and Continue**
4. **Scopes** → Add → search `drive.readonly` → select
   `.../auth/drive.readonly` → Update → Save and Continue
5. **Test users** → add your own Google email (required while app is "Testing")

### Create the OAuth client
1. **APIs & Services → Credentials → + Create Credentials → OAuth client ID**
2. Application type: **iOS**
3. **Bundle ID:** must match your Xcode target's bundle identifier
   (Xcode → target → General → Identity → Bundle Identifier)
4. **Create**, then copy the **Client ID** (ends in `.apps.googleusercontent.com`)

### Build the values for CloudConfig
- `googleClientID` = the full client ID
- The **reversed client ID** = the client ID with its two dot-segments swapped, e.g.
  - Client ID:  `123456-abcdef.apps.googleusercontent.com`
  - Reversed:   `com.googleusercontent.apps.123456-abcdef`
- `googleRedirectURI` = `<reversed-client-id>:/oauth2redirect`
  e.g. `com.googleusercontent.apps.123456-abcdef:/oauth2redirect`

---

## 2b. Dropbox

1. Go to **https://www.dropbox.com/developers/apps** → **Create app**
2. **Scoped access** → **Full Dropbox** (or App folder if you prefer)
3. **Permissions** tab → enable `files.metadata.read` and `files.content.read` → Submit
4. **Settings** tab → **OAuth 2 → Redirect URIs** → add `booklip://auth/dropbox`
5. Copy the **App key** → paste into `CloudConfig.dropboxClientID`
   (Installed apps use PKCE; no app secret needed.)

---

## 3. Fill in CloudConfig.swift

```swift
enum CloudConfig {
    static let oneDriveClientID    = "11111111-2222-3333-4444-555555555555"
    static let oneDriveRedirectURI = "booklip://auth/onedrive"

    static let googleClientID      = "123456-abcdef.apps.googleusercontent.com"
    static let googleRedirectURI   = "com.googleusercontent.apps.123456-abcdef:/oauth2redirect"
}
```

---

## 4. Register URL schemes in Xcode

The app must declare the callback schemes so iOS routes the login redirect
back into the app.

1. Xcode → select the **Booklip** target → **Info** tab
2. Expand **URL Types** (add the section if missing) → **+** twice
3. Entry 1 (OneDrive + Dropbox both use the `booklip` scheme):
   - Identifier: `booklip-auth`
   - URL Schemes: `booklip`
4. Entry 2 (Google):
   - Identifier: `google-auth`
   - URL Schemes: `com.googleusercontent.apps.123456-abcdef`
     (your reversed client ID, **without** the `:/oauth2redirect` part)

---

## 5. Run it

1. Build & run (⌘R)
2. Library → **+** → **Cloud Storage…**
3. Tap **Connect** → the system sign-in sheet appears → log in & grant access
4. Tap **Browse** → navigate your cloud folders
5. Tap any `.txt / .epub / .pdf / .md` file to import it into your library

The login token is stored securely and refreshed automatically; you stay
signed in until you tap **Sign Out**.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Cloud service not configured" | A client ID or redirect URI is still a placeholder in CloudConfig.swift |
| Sign-in sheet closes immediately | URL scheme not registered in Info → URL Types, or redirect URI mismatch |
| "redirect_uri_mismatch" (Google) | Reversed client ID / bundle ID doesn't match the OAuth client |
| OneDrive: AADSTS error about public client | Enable "Allow public client flows" in Authentication |
| Google: "access_denied" while Testing | Add your Google account under OAuth consent → Test users |
