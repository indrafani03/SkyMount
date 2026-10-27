; SkyMount installer for Windows (Inno Setup 6). Build it with scripts\build-windows.ps1, which
; publishes the app and fetches the WinFsp installer first.
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef WinFspMsi
  #define WinFspMsi "winfsp-2.1.25156.msi"
#endif
; Identifies SkyMount to Windows across versions; never change it.
#define AppGuid "7C3B4E2A-5D19-4F6B-9A2E-3B8D1C6F0E41"

[Setup]
AppId={{{#AppGuid}}
AppName=SkyMount
AppVersion={#AppVersion}
AppPublisher=The SkyMount authors
AppCopyright=Copyright 2026 the SkyMount authors
DefaultDirName={autopf}\SkyMount
DisableProgramGroupPage=yes
; WinFsp is a driver, so installing it needs administrator rights.
PrivilegesRequired=admin
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SourceDir=..
OutputDir=build\windows
OutputBaseFilename=SkyMount-{#AppVersion}-setup
SetupIconFile=windows\SkyMount\AppIcon.ico
UninstallDisplayIcon={app}\SkyMount.exe
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes

[Files]
Source: "build\windows\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "LICENSE"; DestDir: "{app}"
Source: "NOTICE"; DestDir: "{app}"
Source: "ThirdPartyLicenses\SSH.NET.txt"; DestDir: "{app}\ThirdPartyLicenses"
Source: "ThirdPartyLicenses\FluentFTP.txt"; DestDir: "{app}\ThirdPartyLicenses"
Source: "ThirdPartyLicenses\WinFsp.txt"; DestDir: "{app}\ThirdPartyLicenses"
Source: "build\windows\{#WinFspMsi}"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsWinFsp

[Icons]
Name: "{autoprograms}\SkyMount"; Filename: "{app}\SkyMount.exe"

[Run]
; Not elevated: drives mounted by an elevated process are invisible to Explorer.
Filename: "{app}\SkyMount.exe"; Description: "Start SkyMount"; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallRun]
; Uploads pending changes, unmounts and exits before the files go away.
Filename: "{app}\SkyMount.exe"; Parameters: "--quit"; Flags: runhidden waituntilterminated; RunOnceId: "QuitSkyMount"

[Registry]
; Open at Login (set from the tray menu) points into the app folder.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "SkyMount"; Flags: uninsdeletevalue dontcreatekey

[Code]
const
  UninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{{#AppGuid}}_is1';

// This version is installed already: offer to repair it (install again over it) or to uninstall it.
// Silent runs repair. Other versions upgrade without asking.
function InitializeSetup: Boolean;
var
  Version, Uninstaller: String;
  ResultCode: Integer;
begin
  Result := True;
  if not RegQueryStringValue(HKLM64, UninstallKey, 'DisplayVersion', Version) or (Version <> '{#AppVersion}') then Exit;
  Log('SkyMount {#AppVersion} is already installed');
  if WizardSilent then Exit;
  case TaskDialogMsgBox('SkyMount {#AppVersion} is already installed.',
         'Repair installs it again over the existing copy, replacing missing or damaged files. '
         + 'Your connections and offline files are kept.' + #13#10#13#10
         + 'Uninstall removes SkyMount from this PC.',
         mbConfirmation, MB_YESNOCANCEL, ['Repair', 'Uninstall'], 0) of
    IDYES:
      Log('Repairing');
    IDNO:
      begin
        if not RegQueryStringValue(HKLM64, UninstallKey, 'UninstallString', Uninstaller)
           or not Exec(RemoveQuotes(Uninstaller), '/SILENT', '', SW_SHOW, ewNoWait, ResultCode) then
          MsgBox('The SkyMount uninstaller could not be started. Run this setup again and choose Repair, '
            + 'then uninstall.', mbError, MB_OK);
        Result := False;
      end;
  else
    Result := False;
  end;
end;

// True unless WinFsp 2.1 or later is installed (the app is built against 2.1).
function NeedsWinFsp: Boolean;
var
  Dir: String;
  Major, Minor, Revision, Build: Word;
begin
  Result := True;
  if RegQueryStringValue(HKLM32, 'SOFTWARE\WinFsp', 'InstallDir', Dir) then
    if GetVersionComponents(AddBackslash(Dir) + 'bin\winfsp-x64.dll', Major, Minor, Revision, Build) then
      Result := (Major < 2) or ((Major = 2) and (Minor < 1));
end;

// An upgrade replaces files the running app uses: let it upload, unmount and exit first.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  if FileExists(ExpandConstant('{app}\SkyMount.exe')) then
    Exec(ExpandConstant('{app}\SkyMount.exe'), '--quit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep <> ssPostInstall) or not NeedsWinFsp then Exit;
  WizardForm.StatusLabel.Caption := 'Installing WinFsp...';
  if not Exec('msiexec.exe', '/i "' + ExpandConstant('{tmp}\{#WinFspMsi}') + '" /qn /norestart', '',
              SW_HIDE, ewWaitUntilTerminated, ResultCode)
     or ((ResultCode <> 0) and (ResultCode <> 3010)) then
    SuppressibleMsgBox('WinFsp could not be installed (error ' + IntToStr(ResultCode) + '). SkyMount needs it to mount '
      + 'drives: install it from https://winfsp.dev/rel/ and start SkyMount again.', mbError, MB_OK, IDOK);
end;
