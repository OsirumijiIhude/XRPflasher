$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

$AppName = "xrp_flasher"
$FirmwareName = "xrp-wpilib-firmware-2.1.0-aa439f0.uf2"
$DistDir = Join-Path $Root "dist"
$BundleDir = Join-Path $Root "build/windows/x64/runner/Release"
$VersionLine = Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern "^version:\s*(.+)$"
$AppVersion = "1.0.0"
if ($VersionLine) {
  $AppVersion = ($VersionLine.Matches[0].Groups[1].Value -split "\+")[0].Trim()
}

flutter config --enable-windows-desktop
if (!(Test-Path (Join-Path $Root "windows"))) {
  flutter create --platforms=windows .
}
flutter build windows --release

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
if (Test-Path (Join-Path $Root $FirmwareName)) {
  Copy-Item (Join-Path $Root $FirmwareName) (Join-Path $BundleDir $FirmwareName) -Force
}

$ZipPath = Join-Path $DistDir "xrp_flasher-windows-x64.zip"
if (Test-Path $ZipPath) {
  Remove-Item $ZipPath -Force
}
Compress-Archive -Path (Join-Path $BundleDir "*") -DestinationPath $ZipPath -Force

$IsccCommand = Get-Command "iscc" -ErrorAction SilentlyContinue
$IsccPath = $null
if ($IsccCommand) {
  $IsccPath = $IsccCommand.Source
}
if (-not $IsccPath) {
  $Candidate = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
  if (Test-Path $Candidate) {
    $IsccPath = $Candidate
  }
}

if ($IsccPath) {
  & $IsccPath (Join-Path $Root "packaging/windows_installer.iss") "/DMyAppVersion=$AppVersion"
  Write-Host "Created $(Join-Path $DistDir 'xrp_flasher-windows-x64-setup.exe')"
} else {
  Write-Host "Inno Setup was not found; created the portable zip only."
}

Write-Host "Created $ZipPath"
