import SwiftUI
import SkyMountCore

struct ConnectionEditor: View {
    @EnvironmentObject private var model: AppModel
    let original: ConnectionConfig

    @State private var draft: ConnectionConfig
    @State private var secrets: [SecretField: String] = [:]
    @State private var savedSecrets: [SecretField: String] = [:]
    @State private var check: CheckState = .none

    private enum CheckState: Equatable {
        case none
        case running(String)
        case passed(String)
        case failed(String)
    }

    init(original: ConnectionConfig) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var status: MountStatus { model.status(of: original.id) }
    private var isDirty: Bool { draft != original || secrets != savedSecrets }
    private var isMounted: Bool { if case .mounted = status { return true } else { return false } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Shown in Finder and the menu"))
                Picker("Type", selection: $draft.kind) {
                    ForEach(BackendKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: draft.kind) { _, kind in draft.port = kind.defaultPort }
            }

            switch draft.kind {
            case .sftp: sftpSection
            case .ftp: ftpSection
            case .s3: s3Section
            case .googleDrive: googleSection
            }

            Section("Options") {
                Toggle("Mount when SkyMount opens", isOn: $draft.autoMount)
                Toggle("Read-only", isOn: $draft.readOnly)
                Stepper(value: $draft.listingTTL, in: 5...300, step: 5) {
                    LabeledContent("Re-read folders after", value: "\(Int(draft.listingTTL)) s")
                }
                .help("Folder listings are reused for this long. Lower values show remote changes sooner but make more requests.")
            }

            if case .failed(let message) = status {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } header: {
                    Text("Last mount attempt")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle(draft.displayName)
        .onAppear(perform: loadSecrets)
    }

    // MARK: Sections

    private var sftpSection: some View {
        Section("Server") {
            serverFields
            Picker("Sign in with", selection: $draft.sftpUseKey) {
                Text("Password").tag(false)
                Text("Private key").tag(true)
            }
            if draft.sftpUseKey {
                HStack {
                    TextField("Key file", text: $draft.sftpKeyPath)
                    Button("Choose…", action: chooseKey)
                }
                SecureField("Key passphrase", text: binding(.keyPassphrase), prompt: Text("Leave empty if the key has none"))
            } else {
                SecureField("Password", text: binding(.password))
            }
            LabeledContent("Server key") {
                if let fp = draft.sftpHostFingerprint {
                    HStack {
                        Text(fp).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Forget") {
                            draft.sftpHostFingerprint = nil
                            model.resetHostKey(original.id)
                        }
                        .help("Use after the server was reinstalled. The next connection trusts the key it sees.")
                    }
                } else {
                    Text("Saved on first connection").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ftpSection: some View {
        Section("Server") {
            serverFields
            SecureField("Password", text: binding(.password))
            Toggle("Require TLS (FTPS)", isOn: $draft.ftpUseTLS)
                .help("Plain FTP sends the password unencrypted. Turn this off only for servers without TLS.")
        }
    }

    @ViewBuilder
    private var serverFields: some View {
        TextField("Address", text: $draft.host, prompt: Text("sftp.example.com"))
        TextField("Port", value: $draft.port, format: .number.grouping(.never))
        TextField("User", text: $draft.username)
        TextField("Folder on server", text: $draft.remotePath, prompt: Text("/"))
    }

    private var s3Section: some View {
        Section {
            TextField("Endpoint", text: $draft.s3Endpoint, prompt: Text("https://s3.amazonaws.com"))
            TextField("Region", text: $draft.s3Region, prompt: Text("us-east-1"))
            TextField("Bucket", text: $draft.s3Bucket)
            TextField("Folder in bucket", text: $draft.remotePath, prompt: Text("/"))
            TextField("Access key ID", text: $draft.s3AccessKey)
            SecureField("Secret access key", text: binding(.s3SecretKey))
            Toggle("Path-style addresses", isOn: $draft.s3PathStyle)
                .help("Needed for MinIO and most S3-compatible services. Amazon S3 works either way.")
        } header: {
            Text("Bucket")
        } footer: {
            Text("Works with Amazon S3, Backblaze B2, Wasabi, Cloudflare R2, and MinIO. Use the endpoint and region your provider lists.")
        }
    }

    private var googleSection: some View {
        Section {
            TextField("OAuth client ID", text: $draft.googleClientID, prompt: Text("…apps.googleusercontent.com"))
            SecureField("OAuth client secret", text: binding(.googleClientSecret))
            LabeledContent("Account") {
                if draft.googleAccount.isEmpty && original.secret(.googleRefreshToken) == nil {
                    Button("Sign In with Google…", action: signInWithGoogle)
                        .disabled(draft.googleClientID.isEmpty || (secrets[.googleClientSecret] ?? "").isEmpty
                                  || isChecking)
                } else {
                    HStack {
                        Text(draft.googleAccount.isEmpty ? "Signed in" : draft.googleAccount)
                        Button("Sign Out") {
                            draft.googleAccount = ""
                            original.setSecret(.googleRefreshToken, nil)
                            save()
                        }
                    }
                }
            }
        } header: {
            Text("Google Drive")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("SkyMount uses your own OAuth client, so no third party sees your files. Create one of type “Desktop app” and enable the Google Drive API.")
                Link("Open Google Cloud credentials", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                Text("Deleted files go to the Drive trash. Google Docs, Sheets, and Slides are not shown because they have no file to download.")
            }
        }
    }

    // MARK: Footer

    private var isChecking: Bool { if case .running = check { return true } else { return false } }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = draft.validationProblem() {
                Label(problem, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            switch check {
            case .none: EmptyView()
            case .running(let what):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(what) }
            case .passed(let message):
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button(isMounted ? "Unmount" : "Mount") {
                    if isDirty { save() }
                    model.toggle(original.id)
                }
                .disabled(draft.validationProblem() != nil || isChecking || { if case .working = status { return true } else { return false } }())
                Spacer()
                Button("Revert") {
                    draft = original
                    secrets = savedSecrets
                    check = .none
                }
                .disabled(!isDirty)
                Button("Test Connection", action: runTest)
                    .disabled(draft.validationProblem() != nil || isChecking)
                Button("Save", action: save)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: Actions

    private func binding(_ field: SecretField) -> Binding<String> {
        Binding(get: { secrets[field] ?? "" }, set: { secrets[field] = $0 })
    }

    private func loadSecrets() {
        var s: [SecretField: String] = [:]
        for f in [SecretField.password, .keyPassphrase, .s3SecretKey, .googleClientSecret] {
            if let v = original.secret(f) { s[f] = v }
        }
        secrets = s
        savedSecrets = s
    }

    private func save() {
        for (field, value) in secrets where savedSecrets[field] != value {
            draft.setSecret(field, value)
        }
        savedSecrets = secrets
        model.upsert(draft)
    }

    private func runTest() {
        save()
        check = .running("Connecting to \(draft.summary.isEmpty ? draft.displayName : draft.summary)…")
        let config = draft
        Task {
            switch await model.test(config) {
            case .success(let message): check = .passed(message)
            case .failure(let error): check = .failed(error.localizedDescription)
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: ("~/.ssh" as NSString).expandingTildeInPath)
        panel.showsHiddenFiles = true
        panel.message = "Choose the private key file (not the .pub file)."
        if panel.runModal() == .OK, let url = panel.url {
            draft.sftpKeyPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func signInWithGoogle() {
        save()
        check = .running("Waiting for Google sign-in in your browser…")
        let client = GoogleOAuth.Client(id: draft.googleClientID, secret: secrets[.googleClientSecret] ?? "")
        Task.detached {
            do {
                let grant = try GoogleOAuth(client: client).authorize { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                await MainActor.run {
                    original.setSecret(.googleRefreshToken, grant.refreshToken)
                    draft.googleAccount = grant.email
                    save()
                    check = .passed(grant.email.isEmpty ? "Signed in." : "Signed in as \(grant.email).")
                }
            } catch {
                await MainActor.run { check = .failed(error.localizedDescription) }
            }
        }
    }
}
