import SwiftUI

struct CloudConnectView: View {
    @StateObject private var oneDrive = OneDriveService()
    @StateObject private var googleDrive = GoogleDriveService()
    let onImport: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showOneDriveBrowser = false
    @State private var showGoogleBrowser   = false

    var body: some View {
        NavigationStack {
            List {
                // OneDrive
                Section {
                    HStack {
                        Image(systemName: "cloud.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 32)
                        VStack(alignment: .leading) {
                            Text("OneDrive")
                                .font(.headline)
                            Text(oneDrive.isSignedIn ? "Connected" : "Not connected")
                                .font(.caption)
                                .foregroundStyle(oneDrive.isSignedIn ? .green : .secondary)
                        }
                        Spacer()
                        if oneDrive.isSignedIn {
                            Button("Browse") { showOneDriveBrowser = true }
                                .buttonStyle(.borderedProminent)
                            Button("Sign Out") { oneDrive.signOut() }
                                .foregroundStyle(.red)
                        } else {
                            Button("Connect") { Task { await oneDrive.signIn() } }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                    if let e = oneDrive.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }

                // Google Drive
                Section {
                    HStack {
                        Image(systemName: "cloud.fill")
                            .foregroundStyle(.red)
                            .frame(width: 32)
                        VStack(alignment: .leading) {
                            Text("Google Drive")
                                .font(.headline)
                            Text(googleDrive.isSignedIn ? "Connected" : "Not connected")
                                .font(.caption)
                                .foregroundStyle(googleDrive.isSignedIn ? .green : .secondary)
                        }
                        Spacer()
                        if googleDrive.isSignedIn {
                            Button("Browse") { showGoogleBrowser = true }
                                .buttonStyle(.borderedProminent)
                            Button("Sign Out") { googleDrive.signOut() }
                                .foregroundStyle(.red)
                        } else {
                            Button("Connect") { Task { await googleDrive.signIn() } }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                    if let e = googleDrive.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Text("Tap Connect to sign in with your account. Once connected, browse your files and tap any supported book (.txt .epub .pdf .md) to import it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cloud Storage")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $showOneDriveBrowser) {
            CloudFileBrowserView(title: "OneDrive", service: oneDrive, onImport: onImport)
                .frame(minWidth: 500, minHeight: 500)
        }
        .sheet(isPresented: $showGoogleBrowser) {
            CloudFileBrowserView(title: "Google Drive", service: googleDrive, onImport: onImport)
                .frame(minWidth: 500, minHeight: 500)
        }
    }
}
