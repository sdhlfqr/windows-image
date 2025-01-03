param(
    [Parameter(Position=0,mandatory=$true)]
    [string] $MountPath,
    [Parameter(Position=1,mandatory=$true)]
    [string] $SourceImagePath,
    [Parameter(Position=2,mandatory=$true)]
    [string] $DesiredVersionName,
    [string] $OSCDIMGPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
)

$WarningPreference      = "SilentlyContinue"
$ErrorActionPreference  = "Stop"

# Globals
$ImagesPath         = "$PSScriptRoot\Images"
$OriginalImageFile  = "$ImagesPath\Original.wim"
$InstallImageFile   = "$ImagesPath\Custom.iso"
$CustomImagePath    = "$ImagesPath\Custom"
$CustomImageFile    = "$CustomImagePath\sources\install.wim"
$ConfigsPath        = "$PSScriptRoot\Configs"
$AnswerFile         = "$ConfigsPath\unattend.xml"
$DriversPath        = "$PSScriptRoot\Drivers"
$PackagesPath       = "$PSScriptRoot\Packages"
$UpdatesPath        = "$PSScriptRoot\Updates"

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
    if (Test-Path "$UpdatesPath\SSU") {
        Write-Host "Installing Servicing Stack Update"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\SSU" | Out-Null
    }

    if (Test-Path "$UpdatesPath\LCU") {
        Write-Host "Installing Latest Cumulative Update"
        $ErrorActionPreference = "SilentlyContinue"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\LCU" | Out-Null
        $ErrorActionPreference = "Stop"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\LCU" | Out-Null
    }

    if (Test-Path "$UpdatesPath\Miscs") {
        Write-Host "Installing Miscs Updates"
        Add-WindowsPackage -Path $MountPath -PackagePath "$UpdatesPath\Miscs" | Out-Null
    }
}

function Install-SystemDrivers {
    if (-not (Test-Path "$DriversPath")) { return }

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
    if (Test-Path "$CongisPath\Disabled-Capabilities.txt") {
        Write-Host "Disabilng Capabilities"
        foreach ($capability in Get-Content "$CongisPath\Disabled-Capabilities.txt") {
            Remove-WindowsCapability -Path $MountPath -Name $capability | Out-Null
        }
    }

    if (Test-Path "$CongisPath\Disabled-Features.txt") {
        Write-Host "Disabilng Features"
        foreach ($feature in Get-Content "$CongisPath\Disabled-Features.txt") {
            Disable-WindowsOptionalFeature -Path $MountPath -FeatureName $feature | Out-Null
        }
    }

    if (Test-Path "$CongisPath\Enabled-Capabilities.txt") {
        Write-Host "Enabling Capabilities"
        foreach ($capability in Get-Content "$CongisPath\Enabled-Capabilities.txt") {
            Add-WindowsCapability -Path $MountPath -Name $capability | Out-Null
        }
    }
    
    if (Test-Path "$CongisPath\Enabled-Features.txt") {
        Write-Host "Enabling Features"
        foreach ($feature in Get-Content "$CongisPath\Enabled-Features.txt") {
            Enable-WindowsOptionalFeature -Path $MountPath -FeatureName $feature | Out-Null
        }
    }
}

function Set-SystemAnswerFile {
    Write-Host "Apply Answer File"

    if (-not (Test-Path $AnswerFile)) { return }

    (-not (Test-Path "$MountPath\Windows\Panther")) -or (Remove-Item -Path "$MountPath\Windows\Panther" -Force -Recurse)  > $null | Out-Null
	New-Item "$MountPath\Windows\Panther" -ItemType Directory | Out-Null

	Copy-Item $AnswerFile "$MountPath\Windows\Panther\unattend.xml" | Out-Null	
}

function Save-InstallImage {
    Write-Host "Saving Install Image"
    Dismount-WindowsImage -Path $MountPath -Save | Out-Null
}

function Get-InstallImage {
    Write-Host "Generating Install Image"
    (-not (Test-Path $InstallImageFile)) -or (Remove-Item -Path $InstallImageFile)  > $null | Out-Null

    & "$OSCDIMGPath\Oscdimg.exe" -b"$OSCDIMGPath\etfsboot.com" -u2 -h "$CustomImagePath" "$InstallImageFile" | Out-Null
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