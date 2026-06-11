<#
.SYNOPSIS
    Increment the AIFF Goose version number stored in version.txt.

.DESCRIPTION
    Reads the current version from installer\version.txt (format: MAJOR.MINOR.PATCH.BUILD).
    Increments the requested component and resets lower components to 0.
    Optionally patches AssemblyInfo.cs or a .csproj SDK-style project file.

.PARAMETER Component
    Which part to bump:
        "major"  ->  x+1.0.0.0
        "minor"  ->  x.y+1.0.0
        "patch"  ->  x.y.z+1.0   (default)
        "build"  ->  x.y.z.b+1

.PARAMETER AssemblyInfoPath
    Optional path to AssemblyInfo.cs. Patched in place if supplied.

.PARAMETER CsprojPath
    Optional path to an SDK-style .csproj. Patches <Version>, <AssemblyVersion>,
    and <FileVersion> elements if present.

.PARAMETER DryRun
    Print what would change; do not write any files.

.EXAMPLE
    .\increment-version.ps1                                        # patch bump
    .\increment-version.ps1 -Component minor                       # minor bump
    .\increment-version.ps1 -Component major -DryRun               # preview only
    .\increment-version.ps1 -CsprojPath ..\src\Goose.csproj        # bump + patch csproj
    .\increment-version.ps1 -AssemblyInfoPath ..\src\Properties\AssemblyInfo.cs
#>
[CmdletBinding()]
param(
    [ValidateSet("major","minor","patch","build")]
    [string]$Component        = "patch",

    [string]$AssemblyInfoPath = "",
    [string]$CsprojPath       = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$versionFile = Join-Path $PSScriptRoot "version.txt"

# ---------------------------------------------------------------------------
# Read or seed version
# ---------------------------------------------------------------------------
if (Test-Path $versionFile) {
    $raw = (Get-Content $versionFile -Raw).Trim()
} else {
    $raw = "1.0.0.0"
    Write-Warning "version.txt not found – seeding with $raw"
}

if ($raw -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "version.txt content '$raw' is not in MAJOR.MINOR.PATCH.BUILD format."
}

[int]$major, [int]$minor, [int]$patch, [int]$build = $raw -split '\.'

# ---------------------------------------------------------------------------
# Increment
# ---------------------------------------------------------------------------
switch ($Component) {
    "major" { $major++; $minor = 0; $patch = 0; $build = 0 }
    "minor" {           $minor++;   $patch = 0; $build = 0 }
    "patch" {                       $patch++;   $build = 0 }
    "build" {                                   $build++   }
}

$newVersion   = "$major.$minor.$patch.$build"
$shortVersion = "$major.$minor.$patch"      # omit build field for AssemblyVersion

Write-Host ""
Write-Host "Version bump ($Component):  $raw  ->  $newVersion" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Write version.txt
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    Set-Content -Path $versionFile -Value $newVersion -NoNewline
    Write-Host "Updated: $versionFile" -ForegroundColor Green
} else {
    Write-Host "[DryRun] Would write '$newVersion' to $versionFile"
}

# ---------------------------------------------------------------------------
# Patch AssemblyInfo.cs
# ---------------------------------------------------------------------------
if ($AssemblyInfoPath) {
    if (-not (Test-Path $AssemblyInfoPath)) {
        Write-Warning "AssemblyInfo.cs not found at '$AssemblyInfoPath' – skipped."
    } else {
        $content = Get-Content $AssemblyInfoPath -Raw
        $content = $content -replace `
            '(\[assembly:\s*AssemblyVersion\s*\(")[\d\.\*]+("\)\])',
            "`${1}$shortVersion.*`${2}"
        $content = $content -replace `
            '(\[assembly:\s*AssemblyFileVersion\s*\(")[\d\.]+("\)\])',
            "`${1}$newVersion`${2}"

        if (-not $DryRun) {
            Set-Content -Path $AssemblyInfoPath -Value $content
            Write-Host "Updated: $AssemblyInfoPath" -ForegroundColor Green
        } else {
            Write-Host "[DryRun] Would patch AssemblyVersion / AssemblyFileVersion in $AssemblyInfoPath"
        }
    }
}

# ---------------------------------------------------------------------------
# Patch SDK-style .csproj
# ---------------------------------------------------------------------------
if ($CsprojPath) {
    if (-not (Test-Path $CsprojPath)) {
        Write-Warning ".csproj not found at '$CsprojPath' – skipped."
    } else {
        [xml]$csproj = Get-Content $CsprojPath -Raw
        $patched = $false

        foreach ($nodeName in "Version","AssemblyVersion","FileVersion") {
            $nodes = $csproj.SelectNodes("//$nodeName")
            foreach ($node in $nodes) {
                $val = switch ($nodeName) {
                    "Version"         { $shortVersion }
                    "AssemblyVersion" { "$shortVersion.0" }
                    "FileVersion"     { $newVersion }
                }
                Write-Host "  $nodeName  ->  $val" -ForegroundColor DarkGreen
                if (-not $DryRun) { $node.InnerText = $val }
                $patched = $true
            }
        }

        if ($patched -and -not $DryRun) {
            $csproj.Save((Resolve-Path $CsprojPath).Path)
            Write-Host "Updated: $CsprojPath" -ForegroundColor Green
        } elseif (-not $patched) {
            Write-Warning "No <Version>, <AssemblyVersion>, or <FileVersion> found in $CsprojPath."
        } else {
            Write-Host "[DryRun] Would patch $CsprojPath"
        }
    }
}

# Return new version string – useful in CI pipelines:
#   $v = .\increment-version.ps1 -Component patch
return $newVersion
