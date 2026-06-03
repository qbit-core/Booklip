import SwiftUI
import UniformTypeIdentifiers

struct CloudConnectView: View {
    @StateObject private var oneDrive = OneDriveService()
    @StateObject private var googleDrive = GoogleDriveService()
    @StateObject private var dropbox = DropboxService()
    let onImport: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showOneDriveBrowser = false
    @State private var showGoogleBrowser   = false
    @State private var showDropboxBrowser  = false

    var body: some View {
        VStack(spacing: 0) {
            // Custom header (gives full control over margins, unlike a nav-bar item)
            ZStack {
                Text("Cloud Storage").font(.headline)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            List {
                // Dropbox
                Section {
                    CloudServiceRow(
                        iconColor: .indigo,
                        name: "Dropbox",
                        status: dropbox.isSignedIn ? "Connected" : "Not connected",
                        statusColor: dropbox.isSignedIn ? .green : .secondary,
                        isConnected: dropbox.isSignedIn,
                        primaryTitle: dropbox.isSignedIn ? "Browse" : "Connect",
                        onPrimary: {
                            if dropbox.isSignedIn { showDropboxBrowser = true }
                            else { Task { await dropbox.signIn() } }
                        },
                        onSignOut: dropbox.isSignedIn ? { dropbox.signOut() } : nil
                    )
                    if let e = dropbox.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }

                // OneDrive
                Section {
                    CloudServiceRow(
                        iconColor: .blue,
                        name: "OneDrive",
                        status: oneDrive.isSignedIn ? "Connected" : "Not connected",
                        statusColor: oneDrive.isSignedIn ? .green : .secondary,
                        isConnected: oneDrive.isSignedIn,
                        primaryTitle: oneDrive.isSignedIn ? "Browse" : "Connect",
                        onPrimary: {
                            if oneDrive.isSignedIn { showOneDriveBrowser = true }
                            else { Task { await oneDrive.signIn() } }
                        },
                        onSignOut: oneDrive.isSignedIn ? { oneDrive.signOut() } : nil
                    )
                    if let e = oneDrive.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }

                // Google Drive
                Section {
                    CloudServiceRow(
                        iconColor: .red,
                        name: "Google Drive",
                        status: googleDrive.isSignedIn ? "Connected" : "Not connected",
                        statusColor: googleDrive.isSignedIn ? .green : .secondary,
                        isConnected: googleDrive.isSignedIn,
                        primaryTitle: googleDrive.isSignedIn ? "Browse" : "Connect",
                        onPrimary: {
                            if googleDrive.isSignedIn { showGoogleBrowser = true }
                            else { Task { await googleDrive.signIn() } }
                        },
                        onSignOut: googleDrive.isSignedIn ? { googleDrive.signOut() } : nil
                    )
                    if let e = googleDrive.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Text("Browse a connected service and tap any supported book (.txt .epub .pdf .md) to import it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .contentMargins(.horizontal, 12, for: .scrollContent)
        }
        .cloudSheetFrame()
        .sheet(isPresented: $showDropboxBrowser) {
            CloudFileBrowserView(title: "Dropbox", service: dropbox, onImport: onImport)
                .cloudSheetFrame()
        }
        .sheet(isPresented: $showOneDriveBrowser) {
            CloudFileBrowserView(title: "OneDrive", service: oneDrive, onImport: onImport)
                .cloudSheetFrame()
        }
        .sheet(isPresented: $showGoogleBrowser) {
            CloudFileBrowserView(title: "Google Drive", service: googleDrive, onImport: onImport)
                .cloudSheetFrame()
        }
    }
}

private extension View {
    // A minimum size only matters on macOS; on iOS forcing a min width wider
    // than the screen pushes content (and the Done button) off the edge.
    @ViewBuilder func cloudSheetFrame() -> some View {
#if os(macOS)
        self.frame(minWidth: 480, minHeight: 420)
#else
        self
#endif
    }
}

// MARK: - Reusable service row

private struct CloudServiceRow: View {
    let iconColor: Color
    let name: String
    let status: String
    let statusColor: Color
    let isConnected: Bool
    let primaryTitle: String
    let onPrimary: () -> Void
    let onSignOut: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "cloud.fill")
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(status).font(.caption).foregroundStyle(statusColor)
                }
                Spacer(minLength: 8)
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
            }
            // Sign Out on its own line so it never crowds the primary button
            if let onSignOut {
                Button("Sign Out", role: .destructive, action: onSignOut)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}
