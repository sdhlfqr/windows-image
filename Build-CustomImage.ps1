param(
    [Parameter(Position=0,mandatory=$true)]
    [string] $MountPath,
    [Parameter(Position=1,mandatory=$true)]
    [string] $SourceImagePath,
    [Parameter(Position=2,mandatory=$true)]
    [string] $DesiredVersionName,
    [string] $WorkspacePath = $PSScriptRoot,
    [string] $OSCDIMGPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
)

$WarningPreference      = "SilentlyContinue"
$ErrorActionPreference  = "Stop"

# Globals
$ImagesPath         = "$WorkspacePath\Images"
$OriginalImageFile  = "$ImagesPath\Original.wim"
$InstallImageFile   = "$ImagesPath\Custom.iso"
$CustomImagePath    = "$ImagesPath\Custom"
$CustomImageFile    = "$CustomImagePath\sources\install.wim"
$ConfigsPath        = "$WorkspacePath\Configs"
$AnswerFile         = "$ConfigsPath\unattend.xml"
$DriversPath        = "$WorkspacePath\Drivers"
$PackagesPath       = "$WorkspacePath\Packages"
$UpdatesPath        = "$WorkspacePath\Updates"

# Methods
function Copy-SourceImage {
    Write-Host "Copying Source Image"
    
    (-not (Test-Path $CustomImagePath)) -or (Remove-Item $CustomImagePath -Force -Recurse) > $null | Out-Null
    
    New-Item $CustomImagePath -ItemType Directory | Out-Null
    Copy-Item -Path "$SourceImagePath\*" -Destination $CustomImagePath -Recurse | Out-Null
    
    (-not (Test-Path $OriginalImageFile)) -or (Remove-Item $OriginalImageFile -Force -Recurse) > $null | Out-Null
    Move-Item -Path $CustomImageFile -Destination $OriginalImageFile | Out-Null
}

function Export-SingleVersion {
    Write-Host "Exporting the Desired Version"

    Export-WindowsImage -SourceImagePath $OriginalImageFile -SourceName $DesiredVersionName -DestinationImagePath $CustomImageFile -DestinationName "$DesiredVersionName (Custom)" | Out-Null
}

function Mount-SystemImage {
    Write-Host "Mounting Custom Image"

    (Test-Path $MountPath) -or (New-Item $MountPath -ItemType Directory) > $null | Out-Null
    
    $ErrorActionPreference = "SilentlyContinue"
    Dismount-WindowsImage -Path $MountPath -Discard | Out-Null

    $ErrorActionPreference = "Stop"
    Mount-WindowsImage -ImagePath $CustomImageFile -Index 1 -Path $MountPath | Out-Null
}

function Install-SystemUpdates {
    if ((Test-Path "$UpdatesPath\SSU") -and (Get-ChildItem "$UpdatesPath\SSU" -Include *.msu, *.cab -Recurse)) {
        Write-Host "Installing Servicing Stack Update"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\SSU" | Out-Null
    }

    if ((Test-Path "$UpdatesPath\LCU") -and (Get-ChildItem "$UpdatesPath\LCU" -Include *.msu, *.cab -Recurse)) {
        Write-Host "Installing Latest Cumulative Update"
        $ErrorActionPreference = "SilentlyContinue"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\LCU" | Out-Null
        $ErrorActionPreference = "Stop"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\LCU" | Out-Null
    }

    if ((Test-Path "$UpdatesPath\Miscs") -and (Get-ChildItem "$UpdatesPath\Miscs" -Include *.msu, *.cab -Recurse)) {
        Write-Host "Installing Miscs Updates"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\Miscs" | Out-Null
    }
}

function Install-SystemDrivers {
    if (-not (Test-Path "$DriversPath")) { return }
    if (-not (Get-ChildItem "$DriversPath" -Filter *.inf -Recurse -ErrorAction SilentlyContinue)) { return }

    Write-Host "Installing Drivers"
    Add-WindowsDriver -Path $MountPath -Driver $DriversPath -Recurse | Out-Null
}

function Install-SystemPackages {
    Write-Host "Installing WinGet"
    Add-AppxProvisionedPackage -Path $MountPath -PackagePath "$PackagesPath\WinGet\Microsoft.VCLibs.appx" -SkipLicense | Out-Null
    Add-AppxProvisionedPackage -Path $MountPath -PackagePath "$PackagesPath\WinGet\Microsoft.UI.Xaml.appx" -SkipLicense | Out-Null
    Add-AppxProvisionedPackage -Path $MountPath -PackagePath "$PackagesPath\WinGet\Microsoft.DesktopAppInstaller.msixbundle" -LicensePath "$PackagesPath\WinGet\Microsoft.DesktopAppInstaller_License.xml" | Out-Null
}

function Set-SystemConfiguration {
    $capabilities = Get-WindowsCapability -Path $MountPath
    $installedCaps = ($capabilities | Where-Object State -eq "Installed").Name
    $notPresentCaps = ($capabilities | Where-Object State -ne "Installed").Name

    $features = Get-WindowsOptionalFeature -Path $MountPath
    $enabledFeatures = ($features | Where-Object State -eq "Enabled").FeatureName
    $disabledFeatures = ($features | Where-Object State -ne "Enabled").FeatureName

    if (Test-Path "$ConfigsPath\Disabled-Capabilities.txt") {
        Write-Host "Disabling Capabilities"
        foreach ($capability in (Get-Content "$ConfigsPath\Disabled-Capabilities.txt" | Where-Object { $_.Trim() })) {
            if ($installedCaps -contains $capability.Trim()) {
                Remove-WindowsCapability -Path $MountPath -Name $capability.Trim() | Out-Null
            }
        }
    }

    if (Test-Path "$ConfigsPath\Disabled-Features.txt") {
        Write-Host "Disabling Features"
        foreach ($feature in (Get-Content "$ConfigsPath\Disabled-Features.txt" | Where-Object { $_.Trim() })) {
            if ($enabledFeatures -contains $feature.Trim()) {
                Disable-WindowsOptionalFeature -Path $MountPath -FeatureName $feature.Trim() | Out-Null
            }
        }
    }

    if (Test-Path "$ConfigsPath\Enabled-Capabilities.txt") {
        Write-Host "Enabling Capabilities"
        foreach ($capability in (Get-Content "$ConfigsPath\Enabled-Capabilities.txt" | Where-Object { $_.Trim() })) {
            if ($notPresentCaps -contains $capability.Trim()) {
                Add-WindowsCapability -Path $MountPath -Name $capability.Trim() | Out-Null
            }
        }
    }
    
    if (Test-Path "$ConfigsPath\Enabled-Features.txt") {
        Write-Host "Enabling Features"
        foreach ($feature in (Get-Content "$ConfigsPath\Enabled-Features.txt" | Where-Object { $_.Trim() })) {
            if ($disabledFeatures -contains $feature.Trim()) {
                Enable-WindowsOptionalFeature -Path $MountPath -FeatureName $feature.Trim() -All | Out-Null
            }
        }
    }
}

function Set-SystemAnswerFile {
    if (-not (Test-Path $AnswerFile) -or (Get-Item $AnswerFile).Length -eq 0) { return }

    Write-Host "Applying Answer File"
    (-not (Test-Path "$MountPath\Windows\Panther")) -or (Remove-Item -Path "$MountPath\Windows\Panther" -Force -Recurse) > $null | Out-Null
    New-Item "$MountPath\Windows\Panther" -ItemType Directory | Out-Null

    Copy-Item $AnswerFile "$MountPath\Windows\Panther\unattend.xml" | Out-Null
}

function Save-InstallImage {
    Write-Host "Saving Install Image"
    Dismount-WindowsImage -Path $MountPath -Save | Out-Null
}

function Get-InstallImage {
    Write-Host "Generating Install Image"
    (-not (Test-Path $InstallImageFile)) -or (Remove-Item -Path $InstallImageFile) > $null | Out-Null

    $bootData = "2#p0,e,b`"$OSCDIMGPath\etfsboot.com`"#pEF,e,b`"$OSCDIMGPath\efisys.bin`""
    & "$OSCDIMGPath\Oscdimg.exe" -m -o -u2 -udfver102 -bootdata:$bootData "$CustomImagePath" "$InstallImageFile" | Out-Null
}

# Main
Write-Host "Initialising Environment..."
Copy-SourceImage
Export-SingleVersion
Mount-SystemImage

Write-Host "Installing Components..."
Install-SystemUpdates
Install-SystemDrivers
#Install-SystemPackages

Write-Host "Configuring System..."
Set-SystemConfiguration
Set-SystemAnswerFile

Write-Host "Building Install Image..."
Save-InstallImage
Get-InstallImage