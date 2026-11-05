param(
    [string]$IsoUrl = "",
    [string]$Edition = "Windows 10 Pro",
    [string]$Release = "22H2",
    [string]$Lang = "English International"
)

$ErrorActionPreference = 'Stop'
$work   = 'C:\work'
$isoDir = "$work\iso"
$mnt    = "$work\mount"
$out    = "$work\out"
New-Item -ItemType Directory -Force $work, $isoDir, $mnt, $out | Out-Null

function Run([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe gagal (exit $LASTEXITCODE)" }
}

# 1. Ambil link ISO (otomatis lewat Fido bila kosong)
if ([string]::IsNullOrWhiteSpace($IsoUrl)) {
    Write-Host "==> Ambil link ISO resmi Microsoft lewat Fido"
    $fido = "$work\Fido.ps1"
    try {
        Invoke-WebRequest "https://raw.githubusercontent.com/pbatard/Fido/v1.70/Fido.ps1" -OutFile $fido -UseBasicParsing
    } catch {
        Write-Host "Tag v1.70 gagal, pakai master"
        Invoke-WebRequest "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1" -OutFile $fido -UseBasicParsing
    }
    $fidoOut = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fido `
        -Win 10 -Rel $Release -Ed Pro -Lang $Lang -Arch x64 -GetUrl
    $IsoUrl = $fidoOut | Where-Object { $_ -match '^https://' } | Select-Object -Last 1
    if (-not $IsoUrl) {
        throw "Fido tidak mengembalikan link. Isi 'iso_url' manual. Output Fido: $($fidoOut -join ' | ')"
    }
    Write-Host "Link ISO didapat."
}

# 1b. Download ISO
Write-Host "==> Download ISO"
Run curl.exe @('-L', '--fail', '--retry', '3', '-o', "$work\source.iso", $IsoUrl)

# 2. Ekstrak isi ISO
Write-Host "==> Ekstrak ISO"
$img   = Mount-DiskImage -ImagePath "$work\source.iso" -PassThru
$drive = ($img | Get-Volume).DriveLetter
robocopy "${drive}:\" $isoDir /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy gagal ($LASTEXITCODE)" }
Dismount-DiskImage -ImagePath "$work\source.iso" | Out-Null
Remove-Item "$work\source.iso" -Force

# 3. Ambil satu edisi saja
$src = "$isoDir\sources\install.wim"
if (-not (Test-Path $src)) { $src = "$isoDir\sources\install.esd" }
$images = Get-WindowsImage -ImagePath $src
$pick = $images | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
if (-not $pick) {
    throw "Edisi '$Edition' tidak ada. Pilihan: $($images.ImageName -join ', ')"
}
Write-Host "==> Pakai edisi: $($pick.ImageName) (index $($pick.ImageIndex))"
Export-WindowsImage -SourceImagePath $src -SourceIndex $pick.ImageIndex `
    -DestinationImagePath "$work\install.wim" | Out-Null
Remove-Item $src -Force

# 4. Mount image
Write-Host "==> Mount install.wim"
Mount-WindowsImage -ImagePath "$work\install.wim" -Index 1 -Path $mnt | Out-Null

# 5. Hapus bloatware
Write-Host "==> Hapus bloatware"
$remove = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp',
    'Microsoft.Getstarted', 'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal', 'Microsoft.OneConnect', 'Microsoft.People',
    'Microsoft.SkypeApp', 'Microsoft.WindowsFeedbackHub', 'Microsoft.YourPhone',
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.WindowsMaps',
    'Microsoft.Messaging', 'Microsoft.Print3D', 'Microsoft.MSPaint',
    'Microsoft.XboxApp', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.Xbox.TCUI', 'Microsoft.Wallet'
)
Get-AppxProvisionedPackage -Path $mnt | Where-Object {
    $n = $_.DisplayName
    $remove | Where-Object { $n -like "$_*" }
} | ForEach-Object {
    Write-Host "   - $($_.DisplayName)"
    Remove-AppxProvisionedPackage -Path $mnt -PackageName $_.PackageName | Out-Null
}

# 6. Tweak registry (offline)
Write-Host "==> Tweak registry"
Run reg.exe @('load', 'HKLM\zSOFTWARE', "$mnt\Windows\System32\config\SOFTWARE")
Run reg.exe @('load', 'HKLM\zNTUSER',   "$mnt\Users\Default\NTUSER.DAT")

function RegDword($path, $name, $value) {
    Run reg.exe @('add', $path, '/v', $name, '/t', 'REG_DWORD', '/d', "$value", '/f')
}

$pol = 'HKLM\zSOFTWARE\Policies\Microsoft\Windows'
RegDword "$pol\DataCollection"  'AllowTelemetry'                 0
RegDword "$pol\Windows Search"  'AllowCortana'                   0
RegDword "$pol\CloudContent"    'DisableWindowsConsumerFeatures' 1
RegDword "$pol\OneDrive"        'DisableFileSyncNGSC'            1
RegDword "$pol\GameDVR"         'AllowGameDVR'                   0

$cdm = 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
RegDword $cdm 'SilentInstalledAppsEnabled'      0
RegDword $cdm 'SystemPaneSuggestionsEnabled'    0
RegDword $cdm 'SubscribedContent-338388Enabled' 0

[gc]::Collect(); Start-Sleep -Seconds 3
Run reg.exe @('unload', 'HKLM\zSOFTWARE')
Run reg.exe @('unload', 'HKLM\zNTUSER')

# 7. Script setelah instalasi selesai
$setupDir = "$mnt\Windows\Setup\Scripts"
New-Item -ItemType Directory -Force $setupDir | Out-Null
@'
@echo off
powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg -h off
'@ | Set-Content "$setupDir\SetupComplete.cmd" -Encoding ASCII

# 8. Bersihkan & simpan
Write-Host "==> Cleanup image"
Run dism.exe @("/Image:$mnt", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
Dismount-WindowsImage -Path $mnt -Save | Out-Null

Write-Host "==> Kompres final install.wim"
Export-WindowsImage -SourceImagePath "$work\install.wim" -SourceIndex 1 `
    -DestinationImagePath "$isoDir\sources\install.wim" -CompressionType Maximum | Out-Null
Remove-Item "$work\install.wim" -Force

# 9. Buat ISO bootable (BIOS + UEFI)
Write-Host "==> Buat ISO"
$osc = (Get-Command oscdimg.exe -ErrorAction SilentlyContinue).Source
if (-not $osc) {
    $osc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Recurse -Filter oscdimg.exe `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $osc) { throw "oscdimg.exe tidak ditemukan" }

$etfs   = "$isoDir\boot\etfsboot.com"
$efisys = "$isoDir\efi\microsoft\boot\efisys.bin"
Run $osc @('-m', '-o', '-u2', '-udfver102',
    "-bootdata:2#p0,e,b${etfs}#pEF,e,b${efisys}",
    '-lWIN10_CUSTOM', $isoDir, "$out\Win10_Custom.iso")

Write-Host "==> Selesai: $out\Win10_Custom.iso"
