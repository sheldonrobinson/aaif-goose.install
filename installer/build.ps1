<#
.SYNOPSIS
    Build one or both AIFF Goose MSI packages with WiX 3.11.

.DESCRIPTION
    Compiles and links Product.wxs + UI.wxs into a signed (optional) MSI.
    Supports per-machine (default) and per-user variants.

.PARAMETER Variant
    "machine"  - per-machine MSI  (default, installs to Program Files)
    "user"     - per-user   MSI  (installs to LocalAppData, no UAC)
    "both"     - build both variants

.PARAMETER SourceDir
    Path to the folder containing Goose.exe.
    Defaults to ..\src\bin\Release relative to the installer folder.

.PARAMETER OutputDir
    Where to place the finished .msi files.
    Defaults to .\output relative to the installer folder.

.PARAMETER Sign
    Sign the MSI with signtool after linking.
    Requires CertThumbprint or a suitable certificate in the current user store.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of a code-signing certificate in the current user store.

.PARAMETER TimestampUrl
    RFC-3161 timestamp server URL.
    Default: http://timestamp.digicert.com

.EXAMPLE
    # Basic build (per-machine, no signing)
    .\build.ps1

    # Build both variants pointing at a custom source directory
    .\build.ps1 -Variant both -SourceDir C:\myapp\bin\Release

    # Signed release build
    .\build.ps1 -Variant both -Sign -CertThumbprint AABBCCDDEEFF00112233445566778899AABBCCDD
#>
[CmdletBinding()]
param(
    [ValidateSet("machine","user","both")]
    [string]$Variant      = "both",

    [string]$ScriptDir    = $PSScriptRoot,
    [string]$SourceDir    = (Join-Path $PSScriptRoot "..\src\bin\Release"),
    [string]$OutputDir    = (Join-Path $PSScriptRoot "output"),

	[switch]$Sign,
    [string]$CertThumbprint = "",
    [string]$TimestampUrl   = "http://timestamp.digicert.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve tool paths
# ---------------------------------------------------------------------------


$null = New-Item -ItemType Directory -Force -Path $OutputDir

$iconDir = Join-Path $ScriptRoot "icons"

# ---------------------------------------------------------------------------
# Determine product version
#   1. Read FileVersion from Goose.exe   (preferred)
#   2. Fall back to version.txt          (used during development)
# ---------------------------------------------------------------------------
$gooseExe = Join-Path $SourceDir "Goose.exe"

$vFile   = Join-Path $ScriptDir "version.txt"
$version = if (Test-Path $vFile) { (Get-Content $vFile -Raw).Trim() } else { "1.0.0.0" }
Write-Warning "Goose.exe not found in SourceDir – using version $version from version.txt."


# Short version for MSI filename (drop 4th field)
$shortVer = ($version -split '\.')[ 0..2 ] -join '.'

$ghRepo      = "aaif-goose/goose"
$downloadUrl = "https://github.com/{0}/releases/download/v{1}/Goose-win32-x64.zip" -f $ghRepo, $shortVer # URL of the ZIP file
$stagingDir  = (Join-Path $ScriptDir "staging")					# Temporary staging folder

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "  AIFF Goose MSI Builder" -ForegroundColor Cyan
Write-Host "  Version     : $version" -ForegroundColor Cyan
Write-Host "  Variant     : $Variant" -ForegroundColor Cyan
Write-Host "  PSScriptRoot:  $PSScriptRoot" -ForegroundColor Cyan
Write-Host "  ScriptDir   : $ScriptDir" -ForegroundColor Cyan
Write-Host "  SourceDir   : $SourceDir" -ForegroundColor Cyan
Write-Host "  downloadUrl : $downloadUrl" -ForegroundColor Cyan
Write-Host "  stagingDir  : $stagingDir" -ForegroundColor Cyan
Write-Host "  OutputDir   : $OutputDir" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Shared candle defines
# ---------------------------------------------------------------------------
$defines = @(
    "-dSourceDir=$SourceDir"
    "-dIconDir=$iconDir"
    "-dProductVersion=$version"
)

# --------------------------------------------------------------------------
# Download and Extract function
# --------------------------------------------------------------------------
function Download-Extract {
	# --- CONFIGURATION ---
	 param(
		[string]$zipUrl,   		# URL of the ZIP file
		[string]$stagingPath,   # Temporary staging folder
		[string]$targetFolder,  # Final destination
		[string]$subfolderName  # Subfolder name inside ZIP (no trailing slash)
	)
	# clean staging
	if (Test-Path $stagingPath) {
		Remove-Item "$stagingPath\*" -Recurse -Force
	}

	# clean target
	if (Test-Path $targetFolder) {
		Remove-Item "$targetFolder\*" -Recurse -Force
	}
	try {
		# Ensure staging directory exists
		New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null

		# Download ZIP
		$zipFilePath = Join-Path $stagingPath "download.zip"
		Write-Host "Downloading ZIP from $zipUrl ..."
		Invoke-WebRequest -Uri $zipUrl -OutFile $zipFilePath -UseBasicParsing

		if (-not (Test-Path $zipFilePath)) {
			throw "Download failed. ZIP file not found."
		}

		# Load .NET ZipArchive
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		$zip = [System.IO.Compression.ZipFile]::OpenRead($zipFilePath)

		# Filter entries for the desired subfolder
		$entries = $zip.Entries | Where-Object { $_.FullName -like "$subfolderName/*" }

		if (-not $entries) {
			$zip.Dispose()
			throw "Subfolder '$subfolderName' not found in ZIP."
		}

		# Ensure target folder exists
		New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null

		Write-Host "Extracting subfolder '$subfolderName' to $targetFolder ..."
		foreach ($entry in $entries) {
			if (-not $entry.FullName.EndsWith("/")) {
				# Compute relative path inside subfolder
				$relativePath = $entry.FullName.Substring($subfolderName.Length + 1)
				$destinationPath = Join-Path $targetFolder $relativePath

				# Ensure parent directory exists
				$parentDir = Split-Path $destinationPath
				if (-not (Test-Path $parentDir)) {
					New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
				}

				# Extract file
				$entryStream = $entry.Open()
				$fileStream = [System.IO.File]::Create($destinationPath)
				$entryStream.CopyTo($fileStream)
				$fileStream.Close()
				$entryStream.Close()
			}
		}

		$zip.Dispose()
		Write-Host "Extraction complete."

	} catch {
		Write-Error "Error: $_"
	}
}

# ---------------------------------------------------------------------------
# Build function
# ---------------------------------------------------------------------------
function Invoke-WixBuild {
    param(
		[string]$WixProject,   # Path to installer.wixproj
        [string]$BuildType,    # BuildType - Machine, User
		[string]$prefix,
		[string]$ProductVersion,
		[string]$ShortVer,
		[string]$SourceDir,
		[string]$OutputDir,
		[string]$OutputMsi
    )

	# Ensure staging directory exists  (clean if exists)
	if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
	New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
	$Scope	   = "per{0}" -f $BuildType
	
	$BuildDir = Join-Path $OutputDir "build"
	if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
	New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
	
	Write-Host "[dotnet] Compiling $(Split-Path $WixProject -Leaf) ..." -ForegroundColor DarkCyan

	$ProductWxs 	= Join-Path $ScriptRoot "Product.wxs"
    
    $IconDir 	= Join-Path $ScriptRoot "icons"
    $ConfigDir 	= Join-Path $ScriptRoot "config"
	
	Write-Host "[wix] Compiling $(Split-Path $ProductWxs -Leaf) ..." -ForegroundColor DarkCyan
	wix build -arch "x64" -outputtype "Package" -culture "en-US" -b $SourceDir -out $OutputMsi `
			  -intermediatefolder $BuildDir -src $ProductWxs -ext WixToolset.Util.wixext -ext WixToolset.UI.wixext `
			  -d BuildType=$BuildType -d ProductVersion=$ProductVersion -d ShortVer=$ShortVer -d Scope=$Scope `
              -d SourceDir=$SourceDir -d IconDir=$IconDir -d ConfigDir=$ConfigDir

    Write-Host "[ok]     $OutputMsi" -ForegroundColor Green
    return $OutputMsi
}

# ---------------------------------------------------------------------------
# Signing helper
# ---------------------------------------------------------------------------
function Invoke-Sign {
    param([string]$MsiPath)
    if (-not $Sign) { return }

    # Auto-locate signtool.exe from Windows SDK
    $st = ""
    if (Test-Path "C:\Program Files (x86)\Windows Kits\10\bin") {
        $st = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" `
                            -Recurse -Filter "signtool.exe" |
              Where-Object { $_.FullName -match 'x64' } |
              Sort-Object FullName -Descending |
              Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $st) { throw "signtool.exe not found. Install the Windows SDK." }

    $signArgs = @("sign", "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256")
    if ($CertThumbprint) {
        $signArgs += @("/sha1", $CertThumbprint)
    } else {
        $signArgs += "/a"   # auto-select best available certificate
    }
    $signArgs += $MsiPath

    Write-Host "[sign]   Signing $(Split-Path $MsiPath -Leaf) ..." -ForegroundColor DarkCyan
    & $st @signArgs
    if ($LASTEXITCODE -ne 0) { throw "signtool.exe failed with exit code $LASTEXITCODE" }
    Write-Host "[ok]     Signed: $MsiPath" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Dispatch builds
# ---------------------------------------------------------------------------
$built = @()

Download-Extract -zipUrl $downloadURL `
				 -stagingPath $stagingDir `
				 -targetFolder $SourceDir `
				 -subfolderName "dist-windows"

if (-not (Test-Path $SourceDir)) {
    throw "SourceDir not found: $SourceDir`nBuild Goose.exe first, or pass -SourceDir."
}


if ($Variant -in "machine","both") {
	$OutputFolder = Join-Path $OutputDir "Machine"
	$prefix = "GooseDesktop-superuser"
	$fileName = "{0}-{1}.msi" -f $prefix, $shortVer
    $msi = Join-Path $OutputFolder $fileName
    Invoke-WixBuild -WixProject (Join-Path $ScriptDir "installer.wixproj") `
					-BuildType  "Machine" `
					-prefix     $prefix `
					-ProductVersion $version `
					-shortVer $shortVer `
					-SourceDir $SourceDir `
					-OutputDir  $OutputFolder `
                    -OutputMsi  $msi 
    Invoke-Sign $msi
    $built += $msi
}

if ($Variant -in "user","both") {
	$OutputFolder = Join-Path $OutputDir "User"
	$prefix = "GooseDesktop-enduser"
	$fileName = "{0}-{1}.msi" -f $prefix, $shortVer
    $msi = Join-Path $OutputFolder $fileName
    Invoke-WixBuild -WixProject (Join-Path $ScriptDir "installer.wixproj") `
					-BuildType  "User" `
					-prefix     $prefix `
					-ProductVersion $version `
					-shortVer $shortVer `
					-SourceDir $SourceDir `
					-OutputDir  $OutputFolder `
                    -OutputMsi  $msi 
    Invoke-Sign $msi
    $built += $msi
}

Write-Host ""
Write-Host "Build complete.  Output files:" -ForegroundColor Cyan
$built | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
Write-Host ""
