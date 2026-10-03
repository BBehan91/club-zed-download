@echo off
setlocal
title Install Club Zed
set "CLUB_ZED_INSTALLER=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:CLUB_ZED_INSTALLER); & ([ScriptBlock]::Create(($text -split '(?m)^# POWERSHELL PAYLOAD\r?\n',2)[1]))"
if errorlevel 1 pause
exit /b
# POWERSHELL PAYLOAD
param(
    [string]$InstallRoot=(Join-Path $env:LOCALAPPDATA 'ClubZed'),
    [string]$ManifestPath,
    [string]$LocalAssetDirectory,
    [switch]$NoLaunch,
    [switch]$NoShortcut,
    [switch]$SkipPrerequisites
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$releaseBase='https://github.com/BBehan91/club-zed-download/releases/'
$mutex=[Threading.Mutex]::new($false,'Local\ClubZedInstaller')
$locked=$false
function Download-File([string]$Url,[string]$Destination) {
    if(-not $Url.StartsWith($releaseBase,[StringComparison]::Ordinal)) {throw 'Unexpected download destination.'}
    for($attempt=1;$attempt -le 3;$attempt++) {
        $client=[Net.WebClient]::new()
        $client.Headers['User-Agent']='Club-Zed-Installer'
        try {$client.DownloadFile($Url,$Destination); return}
        catch {if($attempt -eq 3){throw}; Write-Host 'Connection interrupted. Retrying...'}
        finally {$client.Dispose()}
    }
}
try {
    $locked=$mutex.WaitOne(0)
    if(-not $locked){throw 'Club Zed is already being installed. Use the other installer window.'}
    Write-Host 'CLUB ZED - INSTALL / UPDATE' -ForegroundColor Green
    Write-Host 'Checking the latest Windows game...'
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    if(-not $ManifestPath){$ManifestPath=Join-Path $InstallRoot 'release.json'; Download-File ($releaseBase+'latest/download/release.json') $ManifestPath}
    $release=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if($release.version -notmatch '^[a-zA-Z0-9._-]+$' -or $release.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid release manifest.'}
    $versionRoot=Join-Path $InstallRoot ('versions\'+$release.version)
    $game=Join-Path $versionRoot 'Windows'
    $complete=Join-Path $versionRoot 'install-complete.txt'
    if(-not ((Test-Path $complete) -and (Test-Path (Join-Path $game 'ClubZed\Binaries\Win64\ClubZed.exe')) -and (Test-Path (Join-Path $game 'Launcher.ps1')))) {
        $cache=Join-Path $InstallRoot ('downloads\'+$release.version)
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $partFiles=@(); $partIndex=0
        foreach($part in $release.parts) {
            $partIndex++
            if($part.name -notmatch '^Club-Zed-Windows\.zip\.part[0-9]+$' -or $part.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid game file in manifest.'}
            $file=Join-Path $cache $part.name
            $valid=(Test-Path $file) -and ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $part.sha256)
            if(-not $valid) {
                Write-Host ('Downloading game part {0} of {1} ({2:N0} MB). Please keep this window open...' -f $partIndex,@($release.parts).Count,($part.bytes/1MB))
                if($LocalAssetDirectory){Copy-Item -LiteralPath (Join-Path $LocalAssetDirectory $part.name) -Destination $file -Force}
                else {Download-File $part.url $file}
                if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $part.sha256){throw 'Download verification failed. Run the installer again to retry.'}
            }
            $partFiles+=$file
        }
        if($partFiles.Count -eq 0){throw 'No game files found in the release.'}
        $zip=Join-Path $cache 'Club-Zed-Windows.zip'
        $output=[IO.File]::Create($zip)
        try {foreach($partFile in $partFiles){$inputFile=[IO.File]::OpenRead($partFile);try{$inputFile.CopyTo($output)}finally{$inputFile.Dispose()}}}finally{$output.Dispose()}
        if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $release.sha256){throw 'Game archive verification failed.'}
        Write-Host 'Installing the game. This can take a few minutes...'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try {
            New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
            $allowed=[IO.Path]::GetFullPath($versionRoot).TrimEnd('\')+'\'
            foreach($entry in $archive.Entries) {
                $destination=[IO.Path]::GetFullPath((Join-Path $versionRoot $entry.FullName))
                if(-not $destination.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe archive entry.'}
                if(-not $entry.Name){New-Item -ItemType Directory -Path $destination -Force | Out-Null;continue}
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$destination,$true)
            }
        } finally {$archive.Dispose()}
        if(-not (Test-Path (Join-Path $game 'ClubZed\Binaries\Win64\ClubZed.exe'))){throw 'The game executable is missing from the download.'}
        Set-Content -LiteralPath $complete -Value $release.sha256
        # These exact files were created in this version's download cache.
        foreach($cacheFile in ($partFiles+@($zip))){Remove-Item -LiteralPath $cacheFile -Force}
    }
    if(-not $SkipPrerequisites) {
        $runtime=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
        if(-not $runtime -or $runtime.Installed -ne 1 -or [version]($runtime.Version.TrimStart('v')) -lt [version]'14.44.0.0') {
            $redist=Join-Path $game 'Engine\Extras\Redist\en-us\vc_redist.x64.exe'
            if(Test-Path $redist){Write-Host 'Installing the Microsoft game runtime...';$p=Start-Process $redist -ArgumentList '/install /passive /norestart' -Wait -PassThru;if($p.ExitCode -notin @(0,1638,3010)){throw ('Runtime installation failed: '+$p.ExitCode)}}
        }
    }
    if(-not $NoShortcut) {
        $shell=New-Object -ComObject WScript.Shell
        $desktop=[Environment]::GetFolderPath('Desktop')
        $shortcutPath=Join-Path $desktop 'Club Zed.lnk'
        if(Test-Path $shortcutPath) {
            $existing=$shell.CreateShortcut($shortcutPath)
            if($existing.Arguments -match '-Developer'){$shortcutPath=Join-Path $desktop 'Club Zed Playtest.lnk'}
        }
        $shortcut=$shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $game 'Launcher.ps1')+'"'
        $shortcut.WorkingDirectory=$game
        $shortcut.IconLocation=(Join-Path $game 'ClubZed.exe')+',0'
        $shortcut.Description='Play Club Zed - solo or with friends'
        $shortcut.Save()
    }
    Write-Host 'Installed! Use the Club Zed desktop shortcut to play.' -ForegroundColor Green
    Write-Host 'Multiplayer: install Tailscale, accept your host invitation, and enter the host address and password.'
    if(-not $NoLaunch){Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $game 'Launcher.ps1')+'"') -WindowStyle Hidden}
} catch {Write-Host ('Installation stopped: '+$_.Exception.Message) -ForegroundColor Red;exit 1}
finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
