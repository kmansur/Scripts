<#
.SYNOPSIS
  Coleta inventario da estacao Windows e grava em um CSV unico no pendrive.

.AUTHOR
  Karim Mansur - NetTech

.VERSION
  1.4.0

.DESCRIPTION
  Script para rodar manualmente em cada maquina usando pendrive.
  Nao exige privilegio administrativo.
  Gera ou atualiza o arquivo Inventario_Coletas\Inventario_Geral.csv.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Coleta-Inventario.ps1 -i 453
#>

[CmdletBinding()]
param(
    [Alias("i")]
    [string]$InventoryNumber = "",

    [string]$OutputFolderName = "Inventario_Coletas",

    [string]$InventoryFileName = "Inventario_Geral.csv"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Level,
        [string]$Message
    )

    switch ($Level) {
        "OK"       { Write-Host "[OK] $Message" -ForegroundColor Green }
        "ALERTA"  { Write-Host "[ALERTA] $Message" -ForegroundColor Yellow }
        "CRITICO" { Write-Host "[CRITICO] $Message" -ForegroundColor Red }
        default   { Write-Host "[$Level] $Message" }
    }
}

function Clean-Text {
    param([object]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $value = [string]$Text

    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    return ($value -replace "\s+", " ").Trim()
}

function Get-ScriptDirectory {
    $rootVariable = Get-Variable -Name PSScriptRoot -ErrorAction SilentlyContinue

    if ($rootVariable -and $rootVariable.Value) {
        return $rootVariable.Value
    }

    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-InventoryClass {
    param(
        [string]$ClassName,
        [string]$Filter = "",
        [string]$Namespace = "root\cimv2"
    )

    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            if ($Filter) {
                return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -Filter $Filter -ErrorAction Stop
            }

            return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
        }

        if ($Filter) {
            return Get-WmiObject -Namespace $Namespace -Class $ClassName -Filter $Filter -ErrorAction Stop
        }

        return Get-WmiObject -Namespace $Namespace -Class $ClassName -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-InventoryQuery {
    param(
        [string]$Query,
        [string]$Namespace = "root\cimv2"
    )

    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            return Get-CimInstance -Namespace $Namespace -Query $Query -ErrorAction Stop
        }

        return Get-WmiObject -Namespace $Namespace -Query $Query -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-ObjectPropertySafe {
    param(
        [object]$Object,
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return ""
    }

    $property = $Object.PSObject.Properties[$PropertyName]

    if ($null -eq $property) {
        return ""
    }

    return Clean-Text $property.Value
}

function Get-OSPrettyName {
    param(
        [string]$Caption,
        [string]$Architecture
    )

    $name = Clean-Text $Caption
    $name = $name -replace "Microsoft ", ""
    $name = $name -replace "Windows ", "Win"

    if ($Architecture -match "64") {
        return "$name 64Bits"
    }

    return "$name 32Bits"
}

function Get-OfficeVersion {
    $officeClickToRunPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
    )

    foreach ($path in $officeClickToRunPaths) {
        if (Test-Path $path) {
            try {
                $cfg = Get-ItemProperty -Path $path -ErrorAction Stop

                $productIds = Clean-Text $cfg.ProductReleaseIds
                $version = Clean-Text $cfg.VersionToReport

                if ($productIds -match "O365ProPlus|Microsoft365|O365Business|ProPlusRetail") {
                    return "365 Plus"
                }

                if ($productIds) {
                    return "$productIds $version"
                }
            }
            catch {}
        }
    }

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $uninstallPaths) {
        try {
            $apps = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -match "Microsoft Office|Microsoft 365" -and
                    $_.DisplayName -notmatch "Update|Language|Proofing|MUI|Click-to-Run|Runtime|Visio|Project|Access database engine"
                }

            $officeName = Clean-Text (($apps | Select-Object -First 1).DisplayName)

            if ($officeName) {
                if ($officeName -match "365|Microsoft 365") { return "365 Plus" }
                if ($officeName -match "2021") { return "2021 Plus" }
                if ($officeName -match "2019") { return "2019 Plus" }
                if ($officeName -match "2016") { return "2016 Plus" }
                if ($officeName -match "2013") { return "2013 Plus" }
                if ($officeName -match "2010") { return "2010 Plus" }

                return $officeName
            }
        }
        catch {}
    }

    return ""
}

function Get-AssetTag {
    param(
        [object]$Enclosure
    )

    $assetTag = Get-ObjectPropertySafe -Object $Enclosure -PropertyName "SMBIOSAssetTag"

    if (
        $assetTag -and
        $assetTag -notmatch "No Asset|To Be Filled|Default|None|Unknown|System SKU|Not Specified|Not Applicable"
    ) {
        return $assetTag
    }

    return ""
}

function Convert-MediaType {
    param([object]$MediaType)

    $value = Clean-Text $MediaType

    switch -Regex ($value) {
        "^3$|HDD|Hard Disk" { return "HD" }
        "^4$|SSD"          { return "SSD" }
        "^5$|SCM"          { return "SCM" }
        default            { return "Desconhecido" }
    }
}

function Convert-BusType {
    param([object]$BusType)

    $value = Clean-Text $BusType

    switch -Regex ($value) {
        "^1$"  { return "SCSI" }
        "^2$"  { return "ATAPI" }
        "^3$"  { return "ATA" }
        "^7$"  { return "USB" }
        "^8$"  { return "RAID" }
        "^10$" { return "SAS" }
        "^11$" { return "SATA" }
        "^17$" { return "NVMe" }
        default {
            if ($value) {
                return $value
            }

            return ""
        }
    }
}

function Get-SystemDiskInfo {
    $result = [ordered]@{
        SizeGB = ""
        Type   = "Desconhecido"
        Model  = ""
        Bus    = ""
        Index  = ""
    }

    try {
        $logicalDisk = Get-InventoryClass -ClassName "Win32_LogicalDisk" -Filter "DeviceID='C:'"

        if ($null -ne $logicalDisk -and $logicalDisk.Size) {
            $result.SizeGB = [math]::Round($logicalDisk.Size / 1GB, 0)
        }

        $partitionQuery = "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='C:'} WHERE AssocClass=Win32_LogicalDiskToPartition"
        $partition = Get-InventoryQuery -Query $partitionQuery | Select-Object -First 1

        if ($partition) {
            $partitionDeviceId = Clean-Text $partition.DeviceID
            $diskQuery = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$partitionDeviceId'} WHERE AssocClass=Win32_DiskDriveToDiskPartition"
            $diskDrive = Get-InventoryQuery -Query $diskQuery | Select-Object -First 1

            if ($diskDrive) {
                $result.Model = Clean-Text $diskDrive.Model
                $result.Bus = Clean-Text $diskDrive.InterfaceType
                $result.Index = Clean-Text $diskDrive.Index
            }
        }

        $physicalDisks = @(Get-InventoryClass -Namespace "root\Microsoft\Windows\Storage" -ClassName "MSFT_PhysicalDisk")

        if ($physicalDisks.Count -gt 0) {
            $matchedDisk = $null

            foreach ($pd in $physicalDisks) {
                $pdDeviceId = Clean-Text $pd.DeviceId
                $pdFriendly = Clean-Text $pd.FriendlyName
                $pdModel = Clean-Text (Get-ObjectPropertySafe -Object $pd -PropertyName "Model")

                if ($result.Index -and $pdDeviceId -and $result.Index -eq $pdDeviceId) {
                    $matchedDisk = $pd
                    break
                }

                if ($result.Model -and $pdFriendly -and ($result.Model -match [regex]::Escape($pdFriendly) -or $pdFriendly -match [regex]::Escape($result.Model))) {
                    $matchedDisk = $pd
                    break
                }

                if ($result.Model -and $pdModel -and ($result.Model -match [regex]::Escape($pdModel) -or $pdModel -match [regex]::Escape($result.Model))) {
                    $matchedDisk = $pd
                    break
                }
            }

            if ($null -eq $matchedDisk -and $physicalDisks.Count -eq 1) {
                $matchedDisk = $physicalDisks[0]
            }

            if ($matchedDisk) {
                $mediaType = Convert-MediaType $matchedDisk.MediaType
                $busType = Convert-BusType $matchedDisk.BusType
                $friendlyName = Clean-Text $matchedDisk.FriendlyName

                if ($mediaType -ne "Desconhecido") {
                    $result.Type = $mediaType
                }

                if ($busType) {
                    $result.Bus = $busType
                }

                if (-not $result.Model -and $friendlyName) {
                    $result.Model = $friendlyName
                }
            }
        }

        if ($result.Type -eq "Desconhecido") {
            if ($result.Model -match "SSD|NVMe|M\.2|PCIe|KINGSTON|CRUCIAL|SAMSUNG SSD|SANDISK SDSS|INTEL SSD|ADATA|WDC WDS|PNY|PATRIOT") {
                $result.Type = "SSD"
            }
            elseif ($result.Model -match "HDD|ST[0-9]|WDC WD[0-9]|HGST|TOSHIBA MQ|HTS|HDS|BARRACUDA|MOMENTUS|TRAVELSTAR|IRONWOLF|SKYHAWK") {
                $result.Type = "HD"
            }
        }
    }
    catch {}

    return [pscustomobject]$result
}

function Add-InventoryProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
}

function New-NormalizedRow {
    param(
        [object]$SourceRow,
        [string[]]$Columns
    )

    $normalized = New-Object PSObject

    foreach ($column in $Columns) {
        $value = ""

        if ($null -ne $SourceRow -and $SourceRow.PSObject.Properties[$column]) {
            $value = $SourceRow.PSObject.Properties[$column].Value
        }

        Add-InventoryProperty $normalized $column $value
    }

    return $normalized
}

try {
    Write-Status "OK" "Iniciando coleta de inventario..."

    $scriptDir = Get-ScriptDirectory
    $outputPath = Join-Path $scriptDir $OutputFolderName
    $inventoryFile = Join-Path $outputPath $InventoryFileName

    if (-not (Test-Path $outputPath)) {
        New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
    }

    $columns = @(
        "New Dominium",
        "Local Dominium",
        "User",
        "Operational system",
        "Office Version",
        "Hardware",
        "Model",
        "FA N°",
        "In use",
        "Domain",
        "Manufacturer",
        "ModelOnly",
        "SerialNumber",
        "AssetTagBIOS",
        "InventoryNumberSource",
        "DiskType",
        "DiskModel",
        "DiskBus",
        "DiskSizeGB",
        "CollectedAt"
    )

    $cs = Get-InventoryClass -ClassName "Win32_ComputerSystem"
    $os = Get-InventoryClass -ClassName "Win32_OperatingSystem"
    $cpu = Get-InventoryClass -ClassName "Win32_Processor" | Select-Object -First 1
    $bios = Get-InventoryClass -ClassName "Win32_BIOS"
    $enclosure = Get-InventoryClass -ClassName "Win32_SystemEnclosure" | Select-Object -First 1

    if ($null -eq $cs) {
        throw "Nao foi possivel coletar Win32_ComputerSystem."
    }

    if ($null -eq $os) {
        throw "Nao foi possivel coletar Win32_OperatingSystem."
    }

    $computerName = Clean-Text $env:COMPUTERNAME
    $currentUser = Clean-Text ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

    $domain = if ($cs.PartOfDomain) {
        Clean-Text $cs.Domain
    } else {
        "WORKGROUP"
    }

    $ramGB = ""
    if ($cs.TotalPhysicalMemory) {
        $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
    }

    $diskInfo = Get-SystemDiskInfo
    $diskGB = $diskInfo.SizeGB
    $diskType = $diskInfo.Type
    $diskModel = $diskInfo.Model
    $diskBus = $diskInfo.Bus

    $cpuName = Clean-Text $cpu.Name
    $manufacturer = Clean-Text $cs.Manufacturer
    $modelOnly = Clean-Text $cs.Model
    $model = Clean-Text "$manufacturer $modelOnly"
    $serialNumber = Get-ObjectPropertySafe -Object $bios -PropertyName "SerialNumber"
    $assetTagBIOS = Get-AssetTag -Enclosure $enclosure
    $inventoryNumberClean = Clean-Text $InventoryNumber

    if ($inventoryNumberClean) {
        $faNumber = $inventoryNumberClean
        $inventoryNumberSource = "Parametro -i"
    }
    else {
        $faNumber = $assetTagBIOS
        $inventoryNumberSource = "AssetTagBIOS"
    }

    $hardwareParts = @()

    if ($cpuName) {
        $hardwareParts += $cpuName
    }

    if ($diskGB) {
        if ($diskType -eq "Desconhecido") {
            $hardwareParts += "Disco ${diskGB}GB"
        }
        else {
            $hardwareParts += "$diskType ${diskGB}GB"
        }
    }

    if ($ramGB) {
        $hardwareParts += "${ramGB}GB mem"
    }

    $hardware = $hardwareParts -join " / "

    $row = New-Object PSObject

    Add-InventoryProperty $row "New Dominium"          $computerName
    Add-InventoryProperty $row "Local Dominium"        $computerName
    Add-InventoryProperty $row "User"                  $currentUser
    Add-InventoryProperty $row "Operational system"    (Get-OSPrettyName -Caption $os.Caption -Architecture $os.OSArchitecture)
    Add-InventoryProperty $row "Office Version"        (Get-OfficeVersion)
    Add-InventoryProperty $row "Hardware"              $hardware
    Add-InventoryProperty $row "Model"                 $model
    Add-InventoryProperty $row "FA N°"                 $faNumber
    Add-InventoryProperty $row "In use"                "x"
    Add-InventoryProperty $row "Domain"                $domain
    Add-InventoryProperty $row "Manufacturer"          $manufacturer
    Add-InventoryProperty $row "ModelOnly"             $modelOnly
    Add-InventoryProperty $row "SerialNumber"          $serialNumber
    Add-InventoryProperty $row "AssetTagBIOS"          $assetTagBIOS
    Add-InventoryProperty $row "InventoryNumberSource" $inventoryNumberSource
    Add-InventoryProperty $row "DiskType"              $diskType
    Add-InventoryProperty $row "DiskModel"             $diskModel
    Add-InventoryProperty $row "DiskBus"               $diskBus
    Add-InventoryProperty $row "DiskSizeGB"            $diskGB
    Add-InventoryProperty $row "CollectedAt"           (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    $existingRows = @()

    if (Test-Path $inventoryFile) {
        try {
            $existingRows = @(Import-Csv -Path $inventoryFile -Delimiter ";")
        }
        catch {
            $backupCorrupted = "$inventoryFile.corrompido_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
            Copy-Item -Path $inventoryFile -Destination $backupCorrupted -Force
            Write-Status "ALERTA" "CSV antigo nao foi importado. Backup criado: $backupCorrupted"
            $existingRows = @()
        }
    }

    $filteredRows = @()

    foreach ($existingRowRaw in $existingRows) {
        $existingRow = New-NormalizedRow -SourceRow $existingRowRaw -Columns $columns

        $existingComputer = Clean-Text $existingRow.'New Dominium'
        $existingLocalComputer = Clean-Text $existingRow.'Local Dominium'
        $existingSerial = Clean-Text $existingRow.SerialNumber
        $existingFA = Clean-Text $existingRow.'FA N°'

        $sameMachine = $false

        if ($serialNumber -and $existingSerial -and $serialNumber -eq $existingSerial) {
            $sameMachine = $true
        }

        if ($computerName -and $existingComputer -and $computerName -eq $existingComputer) {
            $sameMachine = $true
        }

        if ($computerName -and $existingLocalComputer -and $computerName -eq $existingLocalComputer) {
            $sameMachine = $true
        }

        if ($faNumber -and $existingFA -and $faNumber -eq $existingFA) {
            $sameMachine = $true
        }

        if (-not $sameMachine) {
            $filteredRows += $existingRow
        }
    }

    $normalizedNewRow = New-NormalizedRow -SourceRow $row -Columns $columns

    $allRows = @()
    $allRows += $filteredRows
    $allRows += $normalizedNewRow

    if (Test-Path $inventoryFile) {
        $backupFile = "$inventoryFile.bak"
        Copy-Item -Path $inventoryFile -Destination $backupFile -Force
    }

    $temporaryFile = "$inventoryFile.tmp"

    $allRows |
        Sort-Object "New Dominium" |
        Export-Csv -Path $temporaryFile -NoTypeInformation -Delimiter ";" -Encoding UTF8 -Force

    Move-Item -Path $temporaryFile -Destination $inventoryFile -Force

    Write-Status "OK" "Inventario atualizado com sucesso."
    Write-Status "OK" "Arquivo: $inventoryFile"

    Write-Host ""
    Write-Host "Resumo:"
    Write-Host "  Computador : $computerName"
    Write-Host "  Usuario    : $currentUser"
    Write-Host "  Sistema    : $($row.'Operational system')"
    Write-Host "  Office     : $($row.'Office Version')"
    Write-Host "  Hardware   : $hardware"
    Write-Host "  Modelo     : $model"
    Write-Host "  FA N°      : $faNumber"
    Write-Host "  Asset BIOS : $assetTagBIOS"
    Write-Host "  Serial     : $serialNumber"
    Write-Host "  Disco      : $diskType $diskGB GB"
    Write-Host "  Disco Bus  : $diskBus"
    Write-Host "  Disco Mod. : $diskModel"
    Write-Host ""

    exit 0
}
catch {
    Write-Status "CRITICO" "Erro na coleta do inventario."
    Write-Host $_.Exception.Message
    exit 1
}