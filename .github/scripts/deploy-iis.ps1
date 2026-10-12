
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{40}$')]
    [string]$ReleaseId
)

$ErrorActionPreference = 'Stop'

$Bucket = 'dotnet-windows-s3'
$ArtifactKey = "artifacts/$ReleaseId.zip"
$LivePath = 'C:\inetpub\wwwroot\HD'
$DeployRoot = 'C:\Deploy'
$StagingRoot = Join-Path $DeployRoot 'staging'
$ReleasePath = Join-Path (Join-Path $DeployRoot 'releases') $ReleaseId
$BackupRoot = 'C:\inetpub\backups\HD'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupPath = Join-Path $BackupRoot "release-$Timestamp"
$ZipPath = Join-Path $StagingRoot "$ReleaseId.zip"
$ExtractPath = Join-Path $StagingRoot "extract-$ReleaseId"

function Test-Website {
    try {
        $response = Invoke-WebRequest `
            -Uri 'http://localhost/' `
            -UseBasicParsing `
            -TimeoutSec 15

        return ($response.StatusCode -eq 200)
    }
    catch {
        Write-Output "Health check failed: $($_.Exception.Message)"
        return $false
    }
}

# Preflight checks: no live website changes in this section.
if (-not (Test-Path $LivePath -PathType Container)) {
    throw "Live website directory not found: $LivePath"
}
if (Test-Path $ReleasePath) {
    throw "Release directory already exists; refusing to overwrite: $ReleasePath"
}
if (-not (Get-Module -ListAvailable -Name AWSPowerShell)) {
    throw 'AWSPowerShell module is not installed.'
}

$null = New-Item -ItemType Directory -Force -Path `
    $StagingRoot, (Join-Path $DeployRoot 'releases'), $BackupRoot

if ((Get-PSDrive C).Free -lt 1GB) {
    throw 'Less than 1 GB free on C:. Aborting deployment.'
}

# Download the exact versioned artifact.
Import-Module AWSPowerShell
Read-S3Object -BucketName $Bucket -Key $ArtifactKey -File $ZipPath

if (-not (Test-Path $ZipPath -PathType Leaf)) {
    throw 'Artifact download did not produce a ZIP file.'
}
if ((Get-Item $ZipPath).Length -le 0) {
    throw 'Downloaded ZIP is empty.'
}

# Validate the ZIP and extract to a separate, non-live directory.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entries = @($archive.Entries)
    if ($entries.Count -eq 0) {
        throw 'Artifact ZIP contains no entries.'
    }
    if ($entries | Where-Object {
        $_.FullName -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)'
    }) {
        throw 'Artifact contains an unsafe path.'
    }
    if (-not ($entries | Where-Object {
        $_.FullName -eq 'index.html'
    })) {
        throw 'Artifact does not contain index.html at its root.'
    }
}
finally {
    $archive.Dispose()
}

if (Test-Path $ExtractPath) {
    Remove-Item $ExtractPath -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $ExtractPath
[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $ExtractPath)

if (-not (Test-Path (Join-Path $ExtractPath 'index.html') -PathType Leaf)) {
    throw 'Extracted website entry file is missing.'
}

# Confirm current live site is healthy before backing it up.
if (-not (Test-Website)) {
    throw 'Current live website is unhealthy. Refusing deployment.'
}

# Back up the current site. Do not delete the original.
$null = New-Item -ItemType Directory -Path $BackupPath
& robocopy $LivePath $BackupPath /E /COPY:DATS /DCOPY:DAT /R:2 /W:2 /XJ
if ($LASTEXITCODE -ge 8) {
    throw "Backup failed with robocopy exit code $LASTEXITCODE."
}

# Prepare release with the existing live-site ACLs.
$null = New-Item -ItemType Directory -Path $ReleasePath
& robocopy $ExtractPath $ReleasePath /E /COPY:DATS /DCOPY:DAT /R:2 /W:2 /XJ
if ($LASTEXITCODE -ge 8) {
    throw "Release copy failed with robocopy exit code $LASTEXITCODE."
}

# Deployment changes the live files. Preserve the backup for rollback.
try {
    & robocopy $ReleasePath $LivePath /E /COPY:DATS /DCOPY:DAT /R:2 /W:2 /XJ
    if ($LASTEXITCODE -ge 8) {
        throw "Live deployment copy failed with robocopy exit code $LASTEXITCODE."
    }

    # Remove stale files from the live directory only after copying.
    & robocopy $ReleasePath $LivePath /MIR /COPY:DATS /DCOPY:DAT /R:2 /W:2 /XJ
    if ($LASTEXITCODE -ge 8) {
        throw "Live sync failed with robocopy exit code $LASTEXITCODE."
    }

    if (-not (Test-Website)) {
        throw 'Post-deployment HTTP health check failed.'
    }

    Write-Output "Deployment succeeded. Release: $ReleaseId"
    Write-Output "Backup retained at: $BackupPath"
}
catch {
    $deployError = $_.Exception.Message
    Write-Output "Deployment failed: $deployError"
    Write-Output 'Attempting rollback from backup...'

    & robocopy $BackupPath $LivePath /MIR /COPY:DATS /DCOPY:DAT /R:2 /W:2 /XJ
    $rollbackCode = $LASTEXITCODE

    if ($rollbackCode -ge 8) {
        throw "Deployment failed AND rollback copy failed (robocopy $rollbackCode). Backup: $BackupPath"
    }
    if (-not (Test-Website)) {
        throw "Rollback copied files, but HTTP health check still fails. Backup: $BackupPath"
    }

    throw "Deployment failed; rollback restored a healthy website. Original error: $deployError"
}
