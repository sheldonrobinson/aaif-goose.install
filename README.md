# AIFF Goose – WiX MSI Installer Project

## Project Structure

```
GooseInstaller/
└── installer/
    ├── build.ps1                   # Main build script
    ├── increment-version.ps1       # Version bump utility
    ├── License.rtf                 # License shown in the installer UI
    ├── version.txt                 # Current version (seed: 1.0.0.0)
    ├── installer.sln               # Visual Studio Solution
    ├── installer.wixproj           # WiX Toolset Project
    ├── Product.wxs                 # MSI Source
    ├── bitmaps/
    │   ├── banner.bmp              # 493x58  top banner
    │   └── dialog.bmp              # 493x312 left panel
    ├── icons/
    │  	├── goose.ico               # ARP / shortcut icon (Application)
    │   ├── help.ico                # ARP / shortcut icon (Help)
    │   ├── info.ico                # ARP / shortcut icon (Information)
    │   ├── start.ico               # ARP / shortcut icon (Start)
    │   ├── stop.ico                # ARP / shortcut icon (Stop)
    │   ├── uninstall.ico           # ARP / shortcut icon (Uninstall)
    │   ├── sysctl.ico              # ARP / shortcut icon (Admin Console)
    │   └── user.ico                # ARP / shortcut icon (User)
    └── config/
        └── config.yaml             # Default config
```

---

## Prerequisites

| Tool                                | Version | Link                                                           |
|-------------------------------------|---------|----------------------------------------------------------------|
| WiX Toolset                         | 5.0.x   | https://wixtoolset.org/releases/                               |
| PowerShell                          | 5.1+    | Built-in on Windows 10/11                                      |
| Windows SDK (optional, for signing) | any     | https://developer.microsoft.com/windows/downloads/windows-sdk/ |

---

## Quick Start

### 1. Build both per-machine and per-user variants (default)

```powershell
.\build.ps1 -Variant both -SourceDir "C:\path\to\your\bin\Release"
```

Outputs:
```
installer\output\Machine\GooseDesktop-superuser-1.0.0.msi
installer\output\User\GooseDesktop-enduser-1.0.0.msi
```

### 2. Build the per-machine MSI 

```powershell
cd installer
.\build.ps1 -Variant machine -SourceDir "C:\path\to\your\bin\Release"
```

Output: `installer\output\Machine\GooseDesktop-superuser-1.0.0.msi`

### 3. Silent install (no UI dialogs baked in)

Pass on the command line at install time without rebuilding:
```
msiexec /i GooseDesktop-enduser-1.0.0.msi /qn
```

### 4. Bump the version

```powershell
.\increment-version.ps1                    # patch:  1.0.0.0 -> 1.0.1.0
.\increment-version.ps1 -Component minor   # minor:  1.0.0.0 -> 1.1.0.0
.\increment-version.ps1 -Component major   # major:  1.0.0.0 -> 2.0.0.0
.\increment-version.ps1 -Component build   # build:  1.0.0.0 -> 1.0.0.1

```

### 5. Sign the MSI

```powershell
.\build.ps1 -Sign -CertThumbprint <your-sha1-thumbprint>
```

---

## Upgrade Matrix

| Scenario                 | Behaviour                                                     |
|--------------------------|---------------------------------------------------------------|
| Newer version over older | Major upgrade – old MSI silently removed, new files installed |
| Same version re-install  | Blocked (`AllowSameVersionUpgrades=no`)                       |
| Older version over newer | Blocked with user-facing error message                        |

`MajorUpgrade` is scheduled `afterInstallInitialize` so old files are removed before new ones are written.

---

## Dialog Sequence

```
WelcomeDlg  ->  InstallDirDlg  ->  VerifyReadyDlg  ->  [install]  ->  ExitDialog
```

- **WelcomeDlg** – standard WiX welcome screen
- **InstallDirDlg** – lets the user pick the install folder (maps to `INSTALLFOLDER`)
- **VerifyReadyDlg** – final confirmation before writing files
- Maintenance mode: `MaintenanceWelcomeDlg -> MaintenanceTypeDlg -> VerifyReadyDlg`

---

## Adding Application Files

In `Product.wxs`, add `<Component>` / `<File>` elements inside the `ProductComponents` group:

```xml
<Component Id="MyDll" Guid="GENERATE-A-NEW-GUID-HERE">
  <File Id="MyDll_file" Name="My.dll"
        Source="$(var.SourceDir)\My.dll" KeyPath="yes" />
</Component>
```

Generate a fresh GUID with PowerShell:
```powershell
[guid]::NewGuid().ToString().ToUpper()
```

or with `msys`
```shell
uuidgen | tr '[:lower:]'  '[:upper:]'
```
---

## Replacing Placeholder Assets

| File                 | Required size            | Notes                                                |
|----------------------|--------------------------|------------------------------------------------------|
| `icons/goose.ico`    | Any, ICO format          | Include 16, 32, 48, 256 px variants for best quality |
| `bitmaps/banner.bmp` | 493 × 58 px, 24-bit BMP  | Top banner strip shown in all dialogs                |
| `bitmaps/dialog.bmp` | 493 × 312 px, 24-bit BMP | Left panel on Welcome / Exit dialogs                 |
| `License.rtf`        | RTF format               | Displayed on the license acceptance screen           |

---

## CI / GitHub Actions Example

```yaml
jobs:
  build-msi:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install WiX
        run: choco install wixtoolset --version 3.14.1 -y

      - name: Bump build version
        run: .\installer\increment-version.ps1 -Component build
        shell: pwsh

      - name: Build MSI (both variants)
        run: .\installer\build.ps1 -Variant both -SourceDir "${{ github.workspace }}\out"
        shell: pwsh

      - name: Upload MSI artifacts
        uses: actions/upload-artifact@v4
        with:
          name: msi-packages
          path: installer\output\*.msi
```
