# SkyMount

SkyMount is a macOS menu bar app that mounts remote storage as ordinary folders in Finder:
SFTP, FTP/FTPS, Amazon S3 and S3-compatible services, and Google Drive. It needs no kernel
extension, no macFUSE and no administrator rights.

A Windows version mounts the same services as network drives in Explorer; see [Windows](#windows).

Website and downloads: [skymount.space](https://skymount.space)

> **Beta.** SkyMount is a personal project tested on one Mac (macOS 27, Apple Silicon). It drives
> the macOS NFS client, and during heavy `git` testing on a mount that client once caused a kernel
> panic (with a mount option SkyMount no longer uses). Keep backups of anything you work on through
> a mount, and report problems in the issue tracker.

## How it works

```
Finder and other apps
        │  ordinary file system calls
        ▼
macOS NFS client  ── mount_nfs <Name>.localhost:/<random token>  ~/SkyMount/<Name>
        │  NFSv3 over TCP, loopback only
        ▼
NFSServer (RFC 1813) + RPCServer (RFC 5531)                  Sources/SkyMountCore/NFS
        │  paths, reads, writes, renames, deletes
        ▼
CachedFileSystem: folder listing cache, file content cache, offline folders   Sources/SkyMountCore/Mount
        │
        ▼
Backends: SFTP (libssh2) · FTP/FTPS (libcurl) · S3 (SigV4) · Google Drive (REST v3)
```

SkyMount runs a small NFSv3 server inside the app, bound to the loopback interface, and asks the
built-in macOS NFS client to mount it. Each volume is mounted through a host name under `.localhost`
(RFC 6761 keeps those on this Mac), so Finder lists it as `PTUMA.localhost` instead of `127.0.0.1`.

- **Reading.** A file is downloaded into the cache the first time it is read and reused while its
  size and modification time on the server stay the same. Files larger than 8 MB are read in 1 MB
  blocks, so opening a large file only fetches the parts that are read. While a download is running
  the server answers `NFS3ERR_JUKEBOX`, which makes the kernel retry instead of declaring the server
  dead.
- **Writing.** Writes go to a local working copy. The file is uploaded when the kernel sends `COMMIT`
  (on close or `fsync`), or after three idle seconds, and everything is uploaded before unmounting.
  Unsent changes are journaled on disk and uploaded at the next mount if the app quits first.
  A failed upload is retried after 5 s, 10 s, 20 s and so on, up to every 5 minutes, and right away
  when the server answers again.
- **Finder metadata** (`._*` and `.DS_Store` files) stays on this Mac and never reaches the server.

## Features

- **Menu bar status.** The icon shows sync arrows while files upload, download or sync, a filled
  drive while something is mounted, and an outline drive otherwise.
- **Keep Offline.** Right-click a folder or file in Finder and choose Keep Offline. Everything inside
  is downloaded and never evicted from the cache. SkyMount checks it against the server at mount time,
  every 10 minutes, and when the network comes back.
- **Working without the server.** When the server cannot be reached, folders kept offline can still
  be opened and read, also after a remount. Other files fail at once with an error instead of
  hanging. Changes written while offline are uploaded when the server is back.
- **Free Up Space** removes cached copies under a folder that is not kept offline.
- **Refresh from Server** re-reads folders now, for changes made on the server (a `git pull`, a deploy).
- **Finder badges.** Green check: available offline. Blue down arrow: downloading. Blue up arrow:
  uploading. Grey clock: waiting to upload. Red exclamation mark: an upload or sync failed and will
  be retried.
- **Mount at login.** Turn on Open at Login in the menu and "Mount when SkyMount opens" for a
  connection. If the network is not up yet, SkyMount tries again when it connects and every
  10 s to 5 minutes until the mount succeeds.
- **Secrets** (passwords, S3 secret keys, Google tokens) live in the Keychain, never in
  `~/Library/Application Support/SkyMount/connections.json`.
- **SFTP host keys** are trusted on first use and pinned by SHA-256 fingerprint. A changed key is
  refused until you press Forget in the connection settings.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- Homebrew `libssh2` and `openssl@3`
- An Apple Development or Developer ID signing identity in the keychain (the Finder extension and the
  app group it shares with the app need a team ID)

## Build

```sh
brew install libssh2 openssl@3
./scripts/build-app.sh          # produces build/SkyMount.app
open build/SkyMount.app
```

The script copies libssh2 and OpenSSL into the bundle, so the built app does not need Homebrew on
another Mac. It signs with the first "Apple Development" identity it finds; set `SIGN_ID` for another
identity (a "Developer ID Application" identity to share builds) and `BUNDLE_ID` for another bundle ID.
Apps built with an Apple Development identity are meant for your own Macs; to give a build to other
people it has to be signed with Developer ID and notarized.

For daily use, copy `build/SkyMount.app` to `/Applications` and turn on Open at Login from there.

### Finder extension

Badges and the Keep Offline menu come from the Finder Sync extension inside the bundle
(`Contents/PlugIns/SkyMountFinder.appex`). Enable it once in **System Settings > General >
Login Items & Extensions > Finder**, or run:

```sh
pluginkit -e use -i id.inkpoint.skymount.finder
```

The app and the extension share state through the app group `<TeamID>.id.inkpoint.skymount`
(`status.json` written by the app, a `requests/` folder written by the extension) and Darwin
notifications.

### smctl

`smctl` is a command-line tool for testing without the app:

```sh
swift build --product smctl
.build/debug/smctl selftest                            # checks S3 SigV4 signing against the AWS example
.build/debug/smctl offlinetest                         # Keep Offline: lost connection, remount, evict, resync (no mount)
.build/debug/smctl local ~/Documents/test LocalTest    # mounts a local folder
.build/debug/smctl sftp host 22 user ~/.ssh/id_ed25519 / Server
```

## Google Drive

SkyMount uses an OAuth client you create, so no third party sees your files.

1. Open [Google Cloud credentials](https://console.cloud.google.com/apis/credentials) and create a
   project if needed.
2. Enable the **Google Drive API** for that project.
3. Create an **OAuth client ID** of type **Desktop app**. Enter its client ID and client secret in
   SkyMount.
4. Press **Sign In with Google…** and approve in the browser. The refresh token is stored in the
   Keychain.

Deleted files go to the Drive trash (restorable for 30 days). Google Docs, Sheets and Slides are not
shown because they have no file contents to download.

## Testing status

Automated tests on the development Mac (macOS 27, Apple Silicon):

| Backend or feature | Test setup | Result |
|---|---|---|
| Local folder | `smctl local` | read, 50 MB write, append, truncate, overwriting rename, mkdir, `rm -r`, outside changes visible |
| SFTP | local OpenSSH `sshd`, key login | 6 to 20 MB reads and writes, rename, delete, fingerprint matches `ssh-keygen` |
| FTP | pyftpdlib 2.0.1 | read, 8 MB write, mkdir, rename, `rm -r` |
| S3 | moto 5.1.4 | read, 9 MB write, mkdir, folder rename, delete; SigV4 matches the AWS example |
| Google Drive | not tested | needs your OAuth client |
| App | SFTP auto-mount, eject from Finder, Quit | volume appears in about 1 s; server cleaned up after eject; Quit unmounts |
| Keep Offline | `smctl offlinetest` (15 checks), app with a local `sshd` that is stopped | offline files readable after the server stops (about 7 s to notice, then instant); a file written offline is uploaded about 2 s after the server returns |
| Mount at login | app started while the server was down | mounted about 10 s after the server came back |
| Finder extension | `pluginkit`, app group folder | Finder loads the extension and it reads the shared status |

## Known limitations

- **S3 uploads use a single request**, so one file can be at most 5 GB. Multipart upload is not
  implemented.
- **Loopback security.** The NFS server listens on `127.0.0.1` only, accepts the owning user's uid or
  root, exports a random path and puts a per-mount random secret in every file handle. macOS does not
  use a privileged source port for mounts made by ordinary users, so another user on the same Mac who
  forges AUTH_SYS credentials could in theory reach a mounted volume. On a single-user Mac this is
  comparable to ordinary folder permissions.
- **Mount point.** Volumes appear under `~/SkyMount/<Name>`, not `/Volumes`, because ordinary users
  cannot create folders in `/Volumes`.
- **Plain FTP** sends the password unencrypted. "Require TLS (FTPS)" is on by default.
- **Google Drive** allows two items with the same name in one folder; SkyMount shows only the oldest.
- **Offline needs a first mount.** Mounting still requires the server; offline folders help once a
  volume is mounted (the connection drops, or the server stops later).
- **The content cache has no size limit** apart from folders kept offline. Use Free Up Space.

## Why NFS rather than macFUSE or WebDAV

- **macFUSE 5** on the development Mac needs an FSKit extension that could not be enabled in System
  Settings.
- **Loopback WebDAV** (the built-in `webdavfs` client) works, but every mount stalled for about
  90 seconds in the `mount()` system call before the volume was usable. This was the same with
  `127.0.0.1`, `[::1]`, `localhost`, in `/Volumes` and in the home folder, with and without
  `nobrowse`.
- **Loopback NFS** mounts in under a second without an extension, a kext or root.

## Windows

The Windows version lives in [windows/](windows). It is a tray app written in C# (.NET 10) that
mounts each connection as a network drive (`S:`, labelled with the connection's name) through
[WinFsp](https://github.com/winfsp/winfsp). The folder listing cache, content cache, Keep Offline
and upload journal work as on macOS; they are a port of the Swift code, not shared with it.

```
Explorer and other apps
        │  ordinary file system calls
        ▼
WinFsp driver  ── network drive S:  (\\SkyMount\<Name>)
        │
        ▼
WinFspFileSystem: Windows names, open files, deletes and renames      windows/SkyMount.Core/Mount
        │
        ▼
CachedFileSystem + WriteBack (working copies, upload journal, retries)
        │
        ▼
Backends: SFTP (SSH.NET) · FTP/FTPS (FluentFTP) · S3 (SigV4) · Google Drive (REST v3)
```

Differences from macOS:

- **WinFsp must be installed once**, which needs administrator rights:
  `winget install WinFsp.WinFsp` or the installer from https://winfsp.dev/rel/. SkyMount itself runs
  without them.
- **Writing.** A file is uploaded three seconds after its last write, when a program flushes it, or
  when the drive is unmounted. New files stay local until then, so temporary files that programs
  delete right away never reach the server.
- **Names.** Names are matched without regard to case, as Windows programs expect; an exact match
  wins when a folder holds both `README` and `readme`. Server names with characters Windows forbids
  (`\ : * ? " < > |`, a trailing dot or space) are shown with look-alike characters (`10：30.log`)
  and keep their real names on the server.
- **Symbolic links** on SFTP servers are shown as the files and folders they point to; broken links
  are left out.
- **No Explorer badges or context menu yet.** Keep a Folder Offline, Free Up Space and the list of
  folders kept offline are in the tray menu.
- **Explorer metadata** (`desktop.ini`, `Thumbs.db`) stays on this PC, like `._*` and `.DS_Store`.
- **Secrets** live in Windows Credential Manager (`SkyMount/…` entries); connections, the cache
  and the upload journal in `%LOCALAPPDATA%\SkyMount`, with a log in `skymount.log`.
- **Open at Login** in the tray menu adds SkyMount to `HKCU\…\CurrentVersion\Run` with `--background`:
  at sign-in it starts in the tray, while starting it by hand (Start menu, installer) opens the
  Connections window.
- The drive is a network drive, so Explorer deletes files permanently (after asking) instead of
  moving them to a Recycle Bin on the server.

### Build and run

Requires Windows 10 or 11, WinFsp 2.1 and the .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`).

```powershell
dotnet build windows\SkyMount.Windows.slnx
windows\SkyMount\bin\Debug\net10.0-windows\SkyMount.exe
```

### Installer

```powershell
winget install JRSoftware.InnoSetup
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1   # produces build\windows\SkyMount-<version>-setup.exe
```

The script publishes the app self-contained (no .NET install needed on the target PC), downloads
the WinFsp 2.1 installer and checks its SHA-256, and packs both with
[windows/SkyMount.iss](windows/SkyMount.iss). The setup program:

- asks for administrator rights, installs into `Program Files\SkyMount` and adds a Start menu entry,
- installs WinFsp silently when it is missing or older than 2.1 (the WinFsp license allows
  distributing its unmodified installer),
- before an upgrade or uninstall runs `SkyMount.exe --quit`, which makes the running app upload
  pending changes, unmount and exit,
- on uninstall leaves WinFsp, `%LOCALAPPDATA%\SkyMount` (it may hold changes not yet uploaded) and
  the saved secrets in place.

Neither the installer nor the app is code-signed, so SmartScreen warns when they are first run. To
sign them, add a `SignTool` entry to `windows/SkyMount.iss` and sign `SkyMount.exe` before packing.

`smctl` works as on macOS and has two more checks:

```powershell
$smctl = "windows\smctl\bin\Debug\net10.0-windows\smctl.exe"
& $smctl selftest                 # S3 SigV4 signing against the AWS example
& $smctl offlinetest              # Keep Offline without a drive (15 checks)
& $smctl mounttest                # a local folder as a drive, worked on with ordinary file calls
& $smctl mounttest C:\srv sftp 127.0.0.1 22 me C:\Users\me\.ssh\id_ed25519 / Test   # the same against a server serving C:\srv
& $smctl local C:\some\folder LocalTest Y                                            # mounts a local folder on Y:
```

Set `SKYMOUNT_WINFSP_LOG` to a file name to log every file system request, and `SKYMOUNT_HOME`
to keep the app's files somewhere other than `%LOCALAPPDATA%\SkyMount`.

### Testing status (Windows)

Windows 11 Home (build 26200), .NET 10, WinFsp 2.1.25156:

| Backend or feature | Test setup | Result |
|---|---|---|
| Local folder | `smctl mounttest` (18 checks) | read, 12 MB block reads, 5 MB write + flush, append, truncate, kept mtime, safe-save rename, case-only rename, `mkdir`, recursive delete, temporary file never uploaded, server changes visible, unmount uploads pending writes |
| SFTP | `smctl mounttest` against asyncssh 2.24.1, ed25519 key | same 18 checks; host key fingerprint pinned |
| FTP | `smctl mounttest` against pyftpdlib 2.2.0, plain FTP | same checks except mtime (FTP cannot set it) |
| S3 | moto 5.2.4, drive worked on from PowerShell | read, 12 MB ranged read, write + flush, replace, folder rename, delete; temporary file never uploaded |
| Keep Offline | `smctl offlinetest` (15 checks) | all pass |
| App | SFTP connection with "Mount when SkyMount opens" | mounted on the chosen letter at launch; host key saved; shown as a network drive; `--quit` uploads a file written just before, unmounts and exits |
| Installer | silent install and uninstall, WinFsp 2.1 already present | WinFsp step skipped; installed app mounts and quits; uninstall removes the folder, Start menu entry and uninstall entry |
| Not tested | | FTPS, Google Drive, Open at Login after a restart, sleep and network changes, the tray menu's folder dialogs, the installer on a PC without WinFsp, upgrading over a running app |

## License

Apache License 2.0, see [LICENSE](LICENSE). Bundled libssh2 (BSD 3-Clause) and OpenSSL (Apache 2.0)
keep their own licenses; see [NOTICE](NOTICE) and [ThirdPartyLicenses](ThirdPartyLicenses). The
Windows build includes SSH.NET and FluentFTP (MIT) and the WinFsp .NET layer, used under the WinFsp
FLOSS exception: WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos,
https://github.com/winfsp/winfsp.
