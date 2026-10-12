
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{40}$')]
    [string]$ReleaseId
)

$ErrorActionPreference = 'Stop'

$Bucket = 'dotnet-windows-s3'
$LivePath = 'C:\inetpub\wwwroot\HD'
$DeployRoot = 'C:\Deploy'
$StagePath = Join-Path $DeployRoot "staging\$ReleaseId"
$ReleasePath = Join-Path $DeployRoot "releases\$ReleaseId"
$BackupRoot = 'C:\inetpub\backups\HD'
$BackupPath = Join-Path $BackupRoot "release-$(Get-Date -Format yyyyMMdd-HHmmss)"
$ZipPath = Join-Path $DeployRoot "$ReleaseId.zip"

function Test-Website {
    try {
        $r = Invoke-WebRequest -Uri 'http://localhost/' `
            -UseBasicParsing -TimeoutSec 15
        return ($r.StatusCode -eq 200)
    } catch {
        Write-Output "Health check failed: $($_.Exception.Message)"
        return $false
    }
}

if (-not (Test-Path "$LivePath\index.html")) {
    throw "Live site entry file is missing: $LivePath"
}
if (Test-Path $ReleasePath) {
    throw "Release already exists; refusing to overwrite it: $ReleasePath"
}
if (-not (Get-Module -ListAvailable -Name AWSPowerShell)) {
    throw 'AWSPowerShell is not installed.'
}
if ((Get-PSDrive C).Free -lt 1GB) {
    throw 'Less than 1 GB free on C:. Deployment aborted.'
}
if (-not (Test-Website)) {
    throw 'Current live website is unhealthy; deployment aborted.'
}

Import-Module AWSPowerShell

$null = New-Item -ItemType Directory -Force -Path `
    $StagePath, (Split-Path $ReleasePath), $BackupRoot

# Download the exact artifact for this release.
Read-S3Object -BucketName $Bucket `
    -Key "artifacts/$ReleaseId.zip" -File $ZipPath

if (-not (Test-Path $ZipPath) -or (Get-Item $ZipPath).Length -eq 0) {
    throw 'Artifact download failed or produced an empty ZIP.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entries = @($archive.Entries)
    if ($entries.Count -eq 0) {
        throw 'Artifact ZIP is empty.'
    }
    if ($entries | Where-Object {
        $_.FullName -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)'
    }) {
        throw 'Unsafe path found in artifact ZIP.'
    }
    if (-not ($entries | Where-Object { $_.FullName -ceq 'index.html' })) {
        throw 'index.html is missing from the ZIP root.'
    }
} finally {
    $archive.Dispose()
}

[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $StagePath)

if (-not (Test-Path "$StagePath\index.html")) {
    throw 'Extracted website is missing index.html.'
}

# Back up the live files and verify the backup before deployment.
$null = New-Item -ItemType Directory -Path $BackupPath
& robocopy $LivePath $BackupPath /E /COPY:DATS /DCOPY:DAT /R:2 /W:2 /XJ
if ($LASTEXITCODE -ge 8) {
    throw "Backup failed (robocopy exit code $LASTEXITCODE)."
}

$liveCount = @(Get-ChildItem $LivePath -File -Recurse).Count
$backupCount = @(Get-ChildItem $BackupPath -File -Recurse).Count
if ($liveCount -ne $backupCount -or -not (Test-Path "$BackupPath\index.html")) {
    throw "Backup verification failed. Live files=$liveCount; backup files=$backupCount"
}

# Prepare the release without copying staging ACLs to the live site.
$null = New-Item -ItemType Directory -Path $ReleasePath
& robocopy $StagePath $ReleasePath /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ
if ($LASTEXITCODE -ge 8) {
    throw "Release preparation failed (robocopy exit code $LASTEXITCODE)."
}

try {
    # /MIR removes stale destination files, so it is used only after backup verification.
    & robocopy $ReleasePath $LivePath /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ
    if ($LASTEXITCODE -ge 8) {
        throw "Live copy failed (robocopy exit code $LASTEXITCODE)."
    }

    if (-not (Test-Website)) {
        throw 'Post-deployment HTTP health check failed.'
    }

    Write-Output "Deployment succeeded: $ReleaseId"
    Write-Output "Backup retained: $BackupPath"
} catch {
    $deploymentError = $_.Exception.Message
    Write-Output "Deployment failed: $deploymentError"
    Write-Output 'Attempting rollback from the verified backup.'

    & robocopy $BackupPath $LivePath /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ
    $rollbackCode = $LASTEXITCODE

    if ($rollbackCode -ge 8) {
        throw "Rollback copy failed (robocopy $rollbackCode). Preserve backup: $BackupPath"
    }
    if (-not (Test-Website)) {
        throw "Rollback copied files but health check failed. Preserve backup: $BackupPath"
    }

    throw "Deployment failed; rollback restored a healthy site. Cause: $deploymentError"
}
