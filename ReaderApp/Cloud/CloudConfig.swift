// MARK: - Cloud Service Configuration
// Fill these in after registering your apps.
//
// OneDrive (Azure):
//   1. Go to https://portal.azure.com → App registrations → New registration
//   2. Name: ReaderApp, Supported account types: Personal Microsoft accounts
//   3. Redirect URI → Mobile and desktop → add: readerapp://auth/onedrive
//   4. API permissions → Add → Microsoft Graph → Files.Read, offline_access
//   5. Copy Application (client) ID below
//
// Google Drive:
//   1. Go to https://console.cloud.google.com → New project
//   2. Enable Google Drive API
//   3. OAuth consent screen → External, add scope: .../auth/drive.readonly
//   4. Credentials → OAuth 2.0 Client ID → iOS → Bundle ID: your.bundle.id
//   5. Copy Client ID below
//
// Dropbox:
//   1. Go to https://www.dropbox.com/developers/apps → Create app
//   2. Choose "Scoped access" → "Full Dropbox" (or App folder)
//   3. Permissions tab → enable files.metadata.read + files.content.read
//   4. Settings tab → OAuth 2 → Redirect URIs → add: readerapp://auth/dropbox
//   5. Copy the App key below
//   (Use PKCE / no app secret for installed apps.)

enum CloudConfig {
    // Microsoft OneDrive
    static let oneDriveClientID   = "YOUR_AZURE_CLIENT_ID"
    static let oneDriveRedirectURI = "readerapp://auth/onedrive"

    // Google Drive
    static let googleClientID     = "157712219209-5bgl7747tqfi85q082ch6si7gcth7hi8.apps.googleusercontent.com"   // ends in .apps.googleusercontent.com
    static let googleRedirectURI  = "com.googleusercontent.apps.157712219209-5bgl7747tqfi85q082ch6si7gcth7hi8:/oauth2redirect"

    // Dropbox
    static let dropboxClientID    = "btx9o6htbdzt7uo"
    static let dropboxRedirectURI = "readerapp://auth/dropbox"
}
