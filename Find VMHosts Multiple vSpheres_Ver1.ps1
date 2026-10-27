
#requires -Version 5.1
# Enterprise vSphere Server Locator
# Tested design target: Windows PowerShell 5.1+ and VMware PowerCLI.
# Read-only inventory. No VM or host configuration changes.
# Install VMware PowerCLI first - then import the module with the two cmds below.
# 1. Install-Module VMware.PowerCLI -Scope CurrentUser
# 2. Import-Module VMware.PowerCLI
# ** NOTE: Installing and Importing take about 3-5 minutes depending on your connection...etc **

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# CONFIGURATION: replace these example vCenter names.
# ------------------------------------------------------------
$VCenters = @(
    "vcsa01.companyA.local",
    "vcsa02.companyB.local",
    "vcsa03.companyB.local"
)

$OutputRoot = "C:\Reports\Enterprise-vSphere"

# Set to $true to ask before each vCenter credential prompt.
$ConfirmEachConnection = $false

# ------------------------------------------------------------
# INITIALIZE
# ------------------------------------------------------------
$RunTime = Get-Date
$Stamp = $RunTime.ToString("yyyy-MM-dd_HHmmss")
$RunFolder = Join-Path $OutputRoot $Stamp
$LatestFolder = Join-Path $OutputRoot "Latest"

New-Item -Path $RunFolder -ItemType Directory -Force |
    Out-Null
New-Item -Path $LatestFolder -ItemType Directory -Force |
    Out-Null

$VMRows = [System.Collections.Generic.List[object]]::new()
$HostRows = [System.Collections.Generic.List[object]]::new()
$FailureRows = [System.Collections.Generic.List[object]]::new()
$ConnectionRows = [System.Collections.Generic.List[object]]::new()

$VIServers = @()
$RunStarted = Get-Date

# ------------------------------------------------------------
# PREREQUISITES
# ------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw "VMware PowerCLI is not installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser"
}

Import-Module VMware.PowerCLI

# Use the default PowerCLI certificate validation behavior.
# Do not globally disable certificate validation in production.

# ------------------------------------------------------------
# CONNECT AND INVENTORY EACH VCENTER
# ------------------------------------------------------------
foreach ($VC in ($VCenters | Select-Object -Unique)) {

    Write-Host "`n====================================" -ForegroundColor DarkCyan
    Write-Host "vCenter: $VC" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor DarkCyan

    if ($ConfirmEachConnection) {
        $Continue = Read-Host "Connect to $VC? (Y/N)"
        if ($Continue -notmatch '^(Y|YES)$') {
            $FailureRows.Add([PSCustomObject]@{
                VCenter = $VC
                Stage = "Skipped"
                Timestamp = Get-Date
                Error = "Skipped by operator"
            })
            continue
        }
    }

    $Connection = $null
    $Stage = "CredentialPrompt"

    try {
        Write-Host "Enter the account for this vCenter."
        Write-Host "Use the appropriate AD or SSO username for $VC."

        $Credential = Get-Credential `
            -Message "Credentials for $VC"

        if ($null -eq $Credential) {
            throw "No credentials supplied."
        }

        $Stage = "Connect"

        $Connection = Connect-VIServer `
            -Server $VC `
            -Credential $Credential `
            -ErrorAction Stop

        $VIServers += $Connection
        $ConnectedAt = Get-Date

        $ConnectionRows.Add([PSCustomObject]@{
            VCenter = $VC
            Status = "Connected"
            ConnectedAt = $ConnectedAt
            VMCount = 0
            HostCount = 0
        })

        Write-Host "Connected successfully." -ForegroundColor Green

        # ----- ESXi hosts -----
        $Stage = "HostInventory"
        $Hosts = @(Get-VMHost -Server $Connection |
            Sort-Object Name)

        foreach ($ESXi in $Hosts) {
            $ClusterName = ""
            $DatacenterName = ""

            if ($ESXi.Parent -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl]) {
                $ClusterName = $ESXi.Parent.Name
                $DatacenterName = $ESXi.Parent.Parent.Name
            }
            else {
                $DatacenterName = $ESXi.Parent.Name
                $ClusterName = "Standalone"
            }

            $HostRows.Add([PSCustomObject]@{
                VCenter = $VC
                Datacenter = $DatacenterName
                Cluster = $ClusterName
                ESXiHost = $ESXi.Name
                ConnectionState = $ESXi.ConnectionState
                PowerState = $ESXi.PowerState
                Version = $ESXi.Version
                Build = $ESXi.Build
                CpuCores = $ESXi.NumCpu
                CpuPackages = $ESXi.ExtensionData.Hardware.CpuInfo.NumCpuPackages
                MemoryGB = [math]::Round($ESXi.MemoryTotalGB, 2)
                VMCount = @(
                    Get-VM -Location $ESXi -Server $Connection
                ).Count
                InventoryTime = Get-Date
            })
        }

        # ----- VMs -----
        $Stage = "VMInventory"
        $VMs = @(Get-VM -Server $Connection |
            Sort-Object Name)

        foreach ($VM in $VMs) {
            $HostObj = $VM.VMHost
            $ClusterName = "Standalone"
            $DatacenterName = ""

            if ($HostObj.Parent -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl]) {
                $ClusterName = $HostObj.Parent.Name
                $DatacenterName = $HostObj.Parent.Parent.Name
            }
            else {
                $DatacenterName = $HostObj.Parent.Name
            }

            # Guest IPs and hostname require guest information
            # reported by VMware Tools and may be unavailable.
            $IPs = @(
                $VM.Guest.IPAddress |
                    Where-Object { $_ } |
                    Sort-Object -Unique
            ) -join "; "

            $GuestHostName = $VM.Guest.HostName
            $GuestOS = $VM.Guest.OSFullName

            $VMRows.Add([PSCustomObject]@{
                VMName = $VM.Name
                GuestHostname = $GuestHostName
                IPAddresses = $IPs
                VCenter = $VC
                Datacenter = $DatacenterName
                Cluster = $ClusterName
                ESXiHost = $HostObj.Name
                PowerState = $VM.PowerState
                GuestOS = $GuestOS
                ConfiguredOS = $VM.ExtensionData.Config.GuestFullName
                NumCPU = $VM.NumCpu
                MemoryGB = [math]::Round($VM.MemoryGB, 2)
                VMVersion = $VM.Version
                VMId = $VM.Id
                Notes = $VM.Notes
                InventoryTime = Get-Date
            })
        }

        $CurrentConnectionRow = $ConnectionRows |
            Where-Object { $_.VCenter -eq $VC } |
            Select-Object -Last 1

        if ($CurrentConnectionRow) {
            $CurrentConnectionRow.VMCount = $VMs.Count
            $CurrentConnectionRow.HostCount = $Hosts.Count
        }

        Write-Host "Hosts: $($Hosts.Count) | VMs: $($VMs.Count)" `
            -ForegroundColor Green
    }
    catch {
        $Message = $_.Exception.Message

        Write-Warning "Failed at stage '$Stage' for $VC : $Message"

        $FailureRows.Add([PSCustomObject]@{
            VCenter = $VC
            Stage = $Stage
            Timestamp = Get-Date
            Error = $Message
        })

        $ConnectionRows.Add([PSCustomObject]@{
            VCenter = $VC
            Status = "Failed: $Stage"
            ConnectedAt = $null
            VMCount = 0
            HostCount = 0
        })
    }
    finally {
        if ($Connection) {
            Disconnect-VIServer -Server $Connection `
                -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Drop the in-memory credential reference.
        $Credential = $null
        $Connection = $null
    }
}

# ------------------------------------------------------------
# EXPORT CSV REPORTS
# ------------------------------------------------------------
$VMFile = "Enterprise-VMs-$Stamp.csv"
$HostFile = "Enterprise-Hosts-$Stamp.csv"
$FailureFile = "Enterprise-Failures-$Stamp.csv"
$StatusFile = "Enterprise-Connections-$Stamp.csv"
$HTMLFile = "Enterprise-ServerLocator-$Stamp.html"

$VMPath = Join-Path $RunFolder $VMFile
$HostPath = Join-Path $RunFolder $HostFile
$FailurePath = Join-Path $RunFolder $FailureFile
$StatusPath = Join-Path $RunFolder $StatusFile
$HTMLPath = Join-Path $RunFolder $HTMLFile

@($VMRows | Sort-Object VMName, VCenter) |
    Export-Csv -Path $VMPath -NoTypeInformation -Encoding UTF8

@($HostRows | Sort-Object VCenter, ESXiHost) |
    Export-Csv -Path $HostPath -NoTypeInformation -Encoding UTF8

@($FailureRows) |
    Export-Csv -Path $FailurePath -NoTypeInformation -Encoding UTF8

@($ConnectionRows) |
    Export-Csv -Path $StatusPath -NoTypeInformation -Encoding UTF8

# ------------------------------------------------------------
# BUILD SEARCHABLE HTML REPORT
# ------------------------------------------------------------
$SortedVMs = @($VMRows | Sort-Object VMName, VCenter)
$VMTable = @(
    $SortedVMs | ConvertTo-Html -Fragment
) -join "`n"

$VMTable = $VMTable -replace '<table>', '<table id="vmTable">'

$HostTable = @(
    ($HostRows | Sort-Object VCenter, ESXiHost) |
        ConvertTo-Html -Fragment
) -join "`n"

$FailureTable = if ($FailureRows.Count -gt 0) {
    @($FailureRows | ConvertTo-Html -Fragment) -join "`n"
} else {
    "<p>No connection or inventory failures recorded.</p>"
}

$ConnectionTable = @(
    $ConnectionRows | ConvertTo-Html -Fragment
) -join "`n"

$Styles = @"
<style>
body { font-family: Arial, sans-serif; margin: 24px; color: #202938; }
h1, h2 { color: #174a75; }
.summary { background: #eef5fb; padding: 14px; margin: 12px 0; }
input { width: 98%; padding: 10px; margin: 12px 0; font-size: 15px; }
table { border-collapse: collapse; width: 100%; margin: 10px 0 28px; font-size: 12px; }
th, td { border: 1px solid #ccd5df; padding: 7px; text-align: left; }
th { background: #174a75; color: white; position: sticky; top: 0; }
tr:nth-child(even) { background: #f3f6f9; }
section { margin-top: 28px; }
</style>
"@

$SearchScript = @"
<script>
function searchVMs() {
  const q = document.getElementById('vmSearch').value.toLowerCase();
  const table = document.getElementById('vmTable');
  for (let i = 1; i < table.rows.length; i++) {
    const row = table.rows[i];
    row.style.display = row.innerText.toLowerCase().includes(q) ? '' : 'none';
  }
}
</script>
"@

$Generated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$Summary = @"
<h1>Enterprise vSphere Server Locator</h1>
<div class="summary">
<p><b>Report generated:</b> $Generated</p>
<p><b>Configured vCenters:</b> $($VCenters.Count)</p>
<p><b>VM records:</b> $($VMRows.Count)</p>
<p><b>ESXi host records:</b> $($HostRows.Count)</p>
<p><b>Failures:</b> $($FailureRows.Count)</p>
<p><b>Important:</b> A failed vCenter may have missing or incomplete inventory.</p>
</div>
<h2>Search Virtual Machines</h2>
<input id="vmSearch" type="text" onkeyup="searchVMs()"
 placeholder="Search VM name, IP, guest hostname, vCenter, cluster or ESXi host...">
"@

$Body = $Summary +
    "<section><h2>VM Inventory</h2>$VMTable</section>" +
    "<section><h2>ESXi Host Inventory</h2>$HostTable</section>" +
    "<section><h2>Connection Status</h2>$ConnectionTable</section>" +
    "<section><h2>Failures</h2>$FailureTable</section>"

ConvertTo-Html -Title "Enterprise vSphere Server Locator" `
    -Head ($Styles + $SearchScript) `
    -Body $Body |
    Set-Content -Path $HTMLPath -Encoding UTF8

# ------------------------------------------------------------
# UPDATE LATEST REPORTS
# ------------------------------------------------------------
Copy-Item $VMPath (Join-Path $LatestFolder "Enterprise-VMs-Latest.csv") -Force
Copy-Item $HostPath (Join-Path $LatestFolder "Enterprise-Hosts-Latest.csv") -Force
Copy-Item $FailurePath (Join-Path $LatestFolder "Enterprise-Failures-Latest.csv") -Force
Copy-Item $StatusPath (Join-Path $LatestFolder "Enterprise-Connections-Latest.csv") -Force
Copy-Item $HTMLPath (Join-Path $LatestFolder "Enterprise-ServerLocator-Latest.html") -Force

# ------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------
$Elapsed = (Get-Date) - $RunStarted

Write-Host "`n====================================" -ForegroundColor Green
Write-Host "ENTERPRISE INVENTORY COMPLETE" -ForegroundColor Green
Write-Host "VMs:      $($VMRows.Count)"
Write-Host "Hosts:    $($HostRows.Count)"
Write-Host "Failures: $($FailureRows.Count)"
Write-Host "Duration: $([math]::Round($Elapsed.TotalMinutes, 2)) minutes"
Write-Host "Latest HTML: $LatestFolder\Enterprise-ServerLocator-Latest.html"
Write-Host "Latest CSV:  $LatestFolder\Enterprise-VMs-Latest.csv"
Write-Host "Run folder:  $RunFolder"
Write-Host "====================================" -ForegroundColor Green

# Open the HTML report in the default browser.
Start-Process (Join-Path $LatestFolder "Enterprise-ServerLocator-Latest.html")
