# Builds build\windows\SkyMount-<version>-setup.exe: the app (self-contained, so no .NET install is
# needed), its licenses and the WinFsp installer, packed with Inno Setup 6.
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
# Needs the .NET 10 SDK and Inno Setup 6: winget install Microsoft.DotNet.SDK.10 JRSoftware.InnoSetup
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\windows'
$version = ([xml](Get-Content (Join-Path $root 'windows\Directory.Build.props'))).Project.PropertyGroup.Version

# The WinFsp release the installer brings along; keep it in step with the winfsp.net package.
$winfsp = 'winfsp-2.1.25156.msi'
$winfspUrl = "https://github.com/winfsp/winfsp/releases/download/v2.1/$winfsp"
$winfspSha256 = '073A70E00F77423E34BED98B86E600DEF93393BA5822204FAC57A29324DB9F7A'

$app = Join-Path $out 'app'
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
dotnet publish (Join-Path $root 'windows\SkyMount\SkyMount.csproj') -c Release -r win-x64 --self-contained -o $app `
    -p:DebugType=none -p:SatelliteResourceLanguages=en
if ($LASTEXITCODE) { throw 'dotnet publish failed' }

$msi = Join-Path $out $winfsp
if (-not (Test-Path $msi)) { Invoke-WebRequest $winfspUrl -OutFile $msi -UseBasicParsing }
if ((Get-FileHash $msi -Algorithm SHA256).Hash -ne $winfspSha256) {
    Remove-Item $msi
    throw "$winfsp does not have the expected SHA-256; it was removed, run the script again to download it again"
}

$iscc = @((Get-Command iscc.exe -ErrorAction SilentlyContinue).Source,
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
          "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 is missing: winget install JRSoftware.InnoSetup' }
& $iscc /Q "/DAppVersion=$version" "/DWinFspMsi=$winfsp" (Join-Path $root 'windows\SkyMount.iss')
if ($LASTEXITCODE) { throw 'Inno Setup failed' }
"Built " + (Join-Path $out "SkyMount-$version-setup.exe")
