<#
.SYNOPSIS
  This is a summary of what the script is.
.DESCRIPTION
  This is a detailed description of what the script does and how it is used.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER cluster
  Nutanix cluster fully qualified domain name or IP address.
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.
.PARAMETER backupPath
  Path where you want to export VM disks and configuration files.
.PARAMETER proxy
  Name of the VM you want to use as a backup proxy for hotadd. Note that if you use a proxy, you will have to trigger backup inside that proxy manually for now.
.PARAMETER vm
  Name of the vm you want to back up/export.

.EXAMPLE
.\backup-ahvVm.ps1 -cluster ntnxc1.local -username admin -password admin
Connect to a Nutanix cluster of your choice:

.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: Oct 3rd 2017
#>

#region parameters
######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)] [switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $true)] [string]$cluster,
    [parameter(mandatory = $false)] [string]$username,
    [parameter(mandatory = $false)] [string]$password,
    [parameter(mandatory = $true)] [string]$vm,
    [parameter(mandatory = $false)] [string]$proxy,
    [parameter(mandatory = $true)] [string]$backupPath,
    [parameter(mandatory = $false)] [switch]$deleteAll
)
#endregion

#region functions
########################
##   main functions   ##
########################

#endregion

#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}
#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 06/19/2015 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\template_prism_rest.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}


#process requirements (PoSH version and modules)
    Write-Host "$(get-date) [INFO] Checking the Powershell version..." -ForegroundColor Green
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "$(get-date) [WARNING] Powershell version is less than 5. Trying to upgrade from the web..." -ForegroundColor Yellow
        if (!$IsLinux) {
            $ChocoVersion = choco
            if (!$ChocoVersion) {
                Write-Host "$(get-date) [WARNING] Chocolatey is not installed!" -ForegroundColor Yellow
                [ValidateSet('y','n')]$ChocoInstall = Read-Host "Do you want to install the chocolatey package manager? (y/n)"
                if ($ChocoInstall -eq "y") {
                    Write-Host "$(get-date) [INFO] Downloading and running chocolatey installation script from chocolatey.org..." -ForegroundColor Green
                    iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
                    Write-Host "$(get-date) [INFO] Downloading and installing the latest Powershell version from chocolatey.org..." -ForegroundColor Green
                    choco install -y powershell
                } else {
                    Write-Host "$(get-date) [ERROR] Please upgrade to Powershell v5 or above manually (https://www.microsoft.com/en-us/download/details.aspx?id=54616)" -ForegroundColor Red
                    Exit
                }#endif choco install
            }#endif not choco
        } else {
            Write-Host "$(get-date) [ERROR] Please upgrade to Powershell v5 or above manually by running sudo apt-get upgrade powershell" -ForegroundColor Red
            Exit
        } #endif not Linux
    }#endif PoSH version
    Write-Host "$(get-date) [INFO] Checking for required Powershell modules..." -ForegroundColor Green
    if (!(Get-Module -Name sbourdeaud)) {
        Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
        try
        {
            Import-Module -Name sbourdeaud -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
        }#end try
        catch #we couldn't import the module, so let's download it
        {
            Write-Host "$(get-date) [INFO] Downloading module 'sbourdeaud' from github..." -ForegroundColor Green
            if (!$IsLinux) {
                $ModulesPath = ($env:PsModulePath -split ";")[0]
                $MyModulePath = "$ModulesPath\sbourdeaud"
            } else {
                $ModulesPath = "~/.local/share/powershell/Modules"
                $MyModulePath = "$ModulesPath/bourdeaud"
            }
            New-Item -Type Container -Force -path $MyModulePath | out-null
            (New-Object net.webclient).DownloadString("https://raw.github.com/sbourdeaud/modules/master/sbourdeaud.psm1") | Out-File "$MyModulePath\sbourdeaud.psm1" -ErrorAction Continue
            (New-Object net.webclient).DownloadString("https://raw.github.com/sbourdeaud/modules/master/sbourdeaud.psd1") | Out-File "$MyModulePath\sbourdeaud.psd1" -ErrorAction Continue

            try
            {
                Import-Module -Name sbourdeaud -ErrorAction Stop
                Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
            }#end try
            catch #we couldn't import the module
            {
                Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "$(get-date) [WARNING] Please download and install from https://github.com/sbourdeaud/modules" -ForegroundColor Yellow
                Exit
            }#end catch
        }#end catch
    }#endif module sbourdeaud

    #let's get ready to use the Nutanix REST API
    #Accept self signed certs
if (!$IsLinux) {
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}#endif not Linux

#endregion

#region variables
#initialize variables
	#misc variables
	$ElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp


    #let's deal with the password
    if (!$password) #if it was not passed as an argument, let's prompt for it
    {
        $PrismSecurePassword = Read-Host "Enter the Prism admin user password" -AsSecureString
    }
    else #if it was passed as an argument, let's convert the string to a secure string and flush the memory
    {
        $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
        Remove-Variable password
    }
    if (!$username) {
        $username = "admin"
    }#endif not username
#endregion

#region parameters validation
	############################################################################
	# command line arguments initialization
	############################################################################	
    if (!(Test-Path $backupPath)) {
        Write-Host "$(get-date) [ERROR] The backup path $backupPath cannot be accessed." -ForegroundColor Red
        Exit
    }
	#let's initialize parameters if they haven't been specified
    
#endregion

#region processing	
	################################
	##  Main execution here       ##
	################################

    #region getting the information we need about the vm and saving its configuration to json
    Write-Host "$(get-date) [INFO] Retrieving list of VMs..." -ForegroundColor Green
    $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/"
    $method = "GET"
    $vmList = Get-PrismRESTCall -method $method -url $url -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword)))
	$vmUuid = ($vmList.entities | where {$_.name -eq $vm}).uuid
    if ($proxy) {$proxyUuid = ($vmList.entities | where {$_.name -eq $proxy}).uuid}
    
    Write-Host "$(get-date) [INFO] Retrieving the configuration of $vm..." -ForegroundColor Green
    $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/$($vmUuid)?include_vm_disk_config=true"
    $method = "GET"
    $vmConfig = Get-PrismRESTCall -method $method -url $url -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword)))
    Write-Host "$(get-date) [SUCCESS] Successfully retrieved the configuration of $vm..." -ForegroundColor Cyan
    
    Write-Host "$(get-date) [INFO] Saving $vm configuration to $($backupPath)$($vm).json..." -ForegroundColor Green
    $vmConfig | ConvertTo-Json | Out-File -FilePath "$($backupPath)$($vm).json"
    
    #$deleteIdentifiers = Get-PrismRESTCall -method DELETE -username $username -password $password -url "https://$($cluster):9440/api/nutanix/v3/idempotence_identifiers/$($env:COMPUTERNAME)"
    if ($IsLinux) {$client_identifier = hostname} else {$client_identifier = "$env:COMPUTERNAME"}
    Write-Host "$(get-date) [INFO] Asking for snapshot id allocation for $($client_identifier)..." -ForegroundColor Green
    $content = @{
            client_identifier = "$($client_identifier)"
            count = 1
        }
    $body = (ConvertTo-Json $content)
    $url = "https://$($cluster):9440/api/nutanix/v3/idempotence_identifiers"
    $method = "POST"
    $snapshotAllocatedId = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body
    Write-Host "$(get-date) [SUCCESS] Successfully obtained a snapshot id allocation!" -ForegroundColor Cyan
    #endregion

    if ($deleteAll) {
        #region delete all backup snapshots
        Write-Host "$(get-date) [INFO] Deleting all snapshots for vm $vm..." -ForegroundColor Green
        $content =@{
            filter = "entity_uuid==$vmUuid"
            kind = "vm_snapshot"
        }
        $body = (ConvertTo-Json $content)
        $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/list"
        $method = "POST"
        Write-Host "$(get-date) [INFO] Retrieving snapshot list..." -ForegroundColor Green
        $backupSnapshots = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved the snapshot list..." -ForegroundColor Cyan
        ForEach ($snapshot in $backupSnapshots.entities) {
            Write-Host "$(get-date) [INFO] Deleting snapshot $($snapshot.metadata.uuid)..." -ForegroundColor Green
            $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/$($snapshot.metadata.uuid)"
            $method = "DELETE"
            Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url                
            Write-Host "$(get-date) [SUCCESS] Successfully deleted snapshot $($snapshot.metadata.uuid)!" -ForegroundColor Cyan
        }
        #endregion
    } else {

        #region creating a snapshot
        Write-Host "$(get-date) [INFO] Creating a crash consistent snapshot of vm $vm..." -ForegroundColor Green
        $snapshotName = "backup.snapshot.$(Get-Date -UFormat "%Y_%m_%d_%H_%M_")$vm"
        $content = @{
                spec = @{
                    resources = @{
                        entity_uuid = "$vmUuid"
                    }
                    snapshot_type = "CRASH_CONSISTENT"
                    name = $snapshotName
                }
                api_version = "3.0"
                metadata = @{
                    kind = "vm_snapshot"
                    uuid = $snapshotAllocatedId.uuid_list[0]
                }
            }
        $body = (ConvertTo-Json $content)
        $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots"
        $method = "POST"
        $snapshotTask = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body
        Write-Host "$(get-date) [INFO] Retrieving status of snapshot $snapshotName ..." -ForegroundColor Green
        Do {
            $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/$($snapshotAllocatedId.uuid_list[0])"
            $method = "GET"
            $snapshotStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
            if ($snapshotStatus.status.state -eq "kError") {
                Write-Host "$(get-date) [ERROR] $($snapshotStatus.status.message_list.message)" -ForegroundColor Red
                Exit
            } elseIf ($snapshotStatus.status.state -eq "COMPLETE") {
                Write-Host "$(get-date) [SUCCESS] $snapshotName status is $($snapshotStatus.status.state)!" -ForegroundColor Cyan
            } else {
                Write-Host "$(get-date) [WARNING] $snapshotName status is $($snapshotStatus.status.state), waiting 5 seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
        } While ($snapshotStatus.status.state -ne "COMPLETE")
        #endregion

        #region using proxy hotadd
        if ($proxy) {
            #region mounting disks on the backup proxy vm
            Write-Host "$(get-date) [INFO] Mounting the $vm snapshots on $proxy..." -ForegroundColor Green
            $snapshotFilePath = $snapshotStatus.status.snapshot_file_list.snapshot_file_path
                                                                $content = @{
                uuid = "$proxyUuid"
                vm_disks = @(foreach ($disk in $snapshotStatus.status.snapshot_file_list.snapshot_file_path) {
                            @{
                    vm_disk_clone = @{
                        disk_address = @{
                            device_bus = "SCSI"
                            ndfs_filepath = "$disk"
                        }
                    }
                            }
                }
                )
            }
            $body = (ConvertTo-Json $content -Depth 4)
            $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/$($proxyUuid)/disks/attach"
            $method = "POST"
            $diskAttachTaskUuid = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body

            Write-Host "$(get-date) [INFO] Checking status of the disk attach task $($diskAttachTaskUuid.task_uuid)..." -ForegroundColor Green
            Do {
                $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/tasks/$($diskAttachTaskUuid.task_uuid)"
                $method = "GET"
                $diskAttachTaskStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
                if ($diskAttachTaskStatus.progress_status -ne "Succeeded") {
                    Write-Host "$(get-date) [WARNING] Disk attach task status is $($diskAttachTaskStatus.progress_status), waiting 5 seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 5
                } else {
                    Write-Host "$(get-date) [SUCCESS] Disk attach task status is $($diskAttachTaskStatus.progress_status)!" -ForegroundColor Cyan
                }
            } While ($diskAttachTaskStatus.progress_status -ne "Succeeded")
            #endregion
            #region backing up data
            #endregion
            #region detaching disks from backup proxy vm
            #endregion
        }#endif proxy
        #endregion

        #region without a proxy
        if (!$proxy) {
            #region restore disks
            #we only waant to restore disk objects from the snapshot, so let's examine the snapshot and determine which objects are attached disks
            ForEach ($file in $snapshotStatus.status.snapshot_file_list) {
                #create a volume group cloning the disk
            }#end foreach file in snapshot
            #now restore those objects on the container in the restore folder
            #endregion
            #region copy data
            #for each restored disk, copy the data to the backup path
            #endregion
            #region delete restored disks
            #delete each restored disk in the restore folder from the container
            #endregion
        }#endif not proxy
        #endregion

        #region Deleting the snapshot
        Write-Host "$(get-date) [INFO] Deleting snapshot $snapshotName..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/$($snapshotAllocatedId.uuid_list[0])"
        $method = "DELETE"
        $snapshotDeletionStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
        Write-Host "$(get-date) [SUCCESS] Successfully deleted snapshot $snapshotName!" -ForegroundColor Cyan

        Write-Host "$(get-date) [INFO] Deleting snapshot identifiers for $($client_identifier)..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v3/idempotence_identifiers/$($client_identifier)"
        $method = "DELETE"
        $deleteIdentifiers = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
        Write-Host "$(get-date) [SUCCESS] Successfully deleted snapshot identifiers for $($client_identifier)!" -ForegroundColor Cyan
        #endregion
    }

#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($ElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta
	
#endregion