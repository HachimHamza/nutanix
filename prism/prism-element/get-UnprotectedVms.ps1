<#
.SYNOPSIS
  This script retrieves the list of unprotected (not in any protection domain) virtual machines from a given Nutanix cluster.
.DESCRIPTION
  The script uses v2 REST API in Prism to GET the list of unprotected VMs from /protection_domains/unprotected_vms/.
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
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER email
  Specifies that you want to email the output. This requires that you set up variables inside the script for smtp gateway and recipients.
.PARAMETER details
  Specifies that you want additional information about each unprotected virtual machines (includes agent vm status, description, number of vdisks and total vdisk size).

.EXAMPLE
.\get-UnprotectedVms.ps1 -cluster ntnxc1.local -username admin -password admin
Retrieve the list of unprotected VMs from cluster ntnxc1.local

.LINK
  http://www.nutanix.com/services
.LINK
  https://github.com/sbourdeaud/nutanix
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: Apr 14th 2020
#>

#region parameters
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
    [parameter(mandatory = $false)] $prismCreds,
    [parameter(mandatory = $false)] [switch]$email,
    [parameter(mandatory = $false)] [switch]$details
)
#endregion

#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}
#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 03/25/2020 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\get-UnprotectedVms.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}

#check PoSH version
if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

#region module sbourdeaud is used for facilitating Prism REST calls
$required_version = "3.0.8"
if (!(Get-Module -Name sbourdeaud)) {
  Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
  try
  {
      Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
      Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
  }#end try
  catch #we couldn't import the module, so let's install it
  {
      Write-Host "$(get-date) [INFO] Installing module 'sbourdeaud' from the Powershell Gallery..." -ForegroundColor Green
      try {Install-Module -Name sbourdeaud -Scope CurrentUser -Force -ErrorAction Stop}
      catch {throw "$(get-date) [ERROR] Could not install module 'sbourdeaud': $($_.Exception.Message)"}

      try
      {
          Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
          Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
      }#end try
      catch #we couldn't import the module
      {
          Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
          Write-Host "$(get-date) [WARNING] Please download and install from https://www.powershellgallery.com/packages/sbourdeaud/1.1" -ForegroundColor Yellow
          Exit
      }#end catch
  }#end catch
}#endif module sbourdeaud
$MyVarModuleVersion = Get-Module -Name sbourdeaud | Select-Object -Property Version
if (($MyVarModuleVersion.Version.Major -lt $($required_version.split('.')[0])) -or (($MyVarModuleVersion.Version.Major -eq $($required_version.split('.')[0])) -and ($MyVarModuleVersion.Version.Minor -eq $($required_version.split('.')[1])) -and ($MyVarModuleVersion.Version.Build -lt $($required_version.split('.')[2])))) {
  Write-Host "$(get-date) [INFO] Updating module 'sbourdeaud'..." -ForegroundColor Green
  Remove-Module -Name sbourdeaud -ErrorAction SilentlyContinue
  Uninstall-Module -Name sbourdeaud -ErrorAction SilentlyContinue
  try {
    Update-Module -Name sbourdeaud -Scope CurrentUser -ErrorAction Stop
    Import-Module -Name sbourdeaud -ErrorAction Stop
  }
  catch {throw "$(get-date) [ERROR] Could not update module 'sbourdeaud': $($_.Exception.Message)"}
}
#endregion
Set-PoSHSSLCerts
Set-PoshTls
#endregion

#region variables

    #! Constants (for -email)
    $smtp_gateway = "" #add your smtp gateway address here
    $smtp_port = 25 #customize the smtp port here if necessary
    $recipients = "" #add a comma separated value of valid email addresses here
    $from = "" #add the from email address here
    $subject = "WARNING: Unprotected VMs in Nutanix cluster $cluster" #customize the subject here
    $body = "Please open the attached csv file and make sure the VMs listed are in protection domains on cluster $cluster"

    #initialize variables
	$ElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp

    [System.Collections.ArrayList]$myvarResults = New-Object System.Collections.ArrayList($null)
#endregion

#region parameters validation
if (!$prismCreds) 
{#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
    if (!$username) 
    {#if Prism username has not been specified ask for it
        $username = Read-Host "Enter the Prism username"
    } 

    if (!$password) 
    {#if password was not passed as an argument, let's prompt for it
        $PrismSecurePassword = Read-Host "Enter the Prism user $username password" -AsSecureString
    }
    else 
    {#if password was passed as an argument, let's convert the string to a secure string and flush the memory
        $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
        Remove-Variable password
    }
    $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
} 
else 
{ #we are using custom credentials, so let's grab the username and password from that
    try 
    {
        $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
        $username = $prismCredentials.UserName
        $PrismSecurePassword = $prismCredentials.Password
    }
    catch 
    {
        $credname = Read-Host "Enter the credentials name"
        Set-CustomCredentials -credname $credname
        $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
        $username = $prismCredentials.UserName
        $PrismSecurePassword = $prismCredentials.Password
    }
    $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
}
    
#endregion

#region processing	
	
    #retrieving all AHV vm information
    Write-Host "$(get-date) [INFO] Retrieving list of unprotected VMs..." -ForegroundColor Green
    $url = "https://$($cluster):9440/api/nutanix/v2.0/protection_domains/unprotected_vms/"
    $method = "GET"
    $vmList = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials
    Write-Host "$(get-date) [SUCCESS] Successfully retrieved unprotected VMs list from $cluster!" -ForegroundColor Cyan

    if ($details) {
        Write-Host "$(get-date) [INFO] Retrieving details for VMs on cluster ($cluster)..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v2.0/vms?include_vm_disk_config=true&include_vm_nic_config=true"
        $method = "GET"
        $vmsDetails = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved details for VMs on cluster ($cluster)!" -ForegroundColor Cyan

        Write-Host "$(get-date) [INFO] Retrieving details for virtual disks on cluster $($cluster)..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v2.0/virtual_disks/"
        $method = "GET"
        $disksDetails = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved details for virtual disks on cluster $($cluster)!" -ForegroundColor Cyan

        Write-Host "$(get-date) [INFO] Retrieving details for volume groups on cluster $($cluster)..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v2.0/volume_groups/"
        $method = "GET"
        $vgsDetails = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved details for volume groups on cluster $($cluster)!" -ForegroundColor Cyan
    }
    
    Foreach ($vm in $vmList.entities) {
        if ($debugme) {Write-Host "$(get-date) [DEBUG] ----------- VM: $($vm.vm_name)) -----------" -ForegroundColor White}
        if ($details) {

            $vmDetails = $vmsDetails.entities | Where-Object {$_.name -eq $vm.vm_name}
            $vmDisks = $vmDetails.vm_disk_info | Where-Object {$_.is_cdrom -eq $false}
            $total_vdisk_size_bytes_used = 0
            $total_vdisk_size_bytes_allocated = 0
            
            Foreach ($disk in $vmDisks) {
                if ($disk.disk_address.vmdisk_uuid) {
                    if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Found a virtual disk." -ForegroundColor White}
                    $total_vdisk_size_bytes_used += ($disksDetails.entities | Where-Object {$_.uuid -eq $disk.disk_address.vmdisk_uuid}).stats.controller_user_bytes
                    if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Bytes used for this disk: $(($disksDetails.entities | Where-Object {$_.uuid -eq $disk.disk_address.vmdisk_uuid}).stats.controller_user_bytes)" -ForegroundColor White}
                    $total_vdisk_size_bytes_allocated += ($disksDetails.entities | Where-Object {$_.uuid -eq $disk.disk_address.vmdisk_uuid}).disk_capacity_in_bytes
                    if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Bytes allocated for this disk: $(($disksDetails.entities | Where-Object {$_.uuid -eq $disk.disk_address.vmdisk_uuid}).disk_capacity_in_bytes)" -ForegroundColor White}
                } elseif ($disk.disk_address.volume_group_uuid) {
                    if ($debugme) {Write-Host "$(get-date) [DEBUG]           VG BEGIN*******" -ForegroundColor White}
                    if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Found a volume group." -ForegroundColor White}
                    $vg_disk_list = ($vgsDetails.entities | Where-Object {$_.uuid -eq $disk.disk_address.volume_group_uuid}).disk_list
                    if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) This volume group has $($vg_disk_list.Count) disks." -ForegroundColor White}
                    Foreach ($vg_disk in $vg_disk_list) {
                        if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Found a virtual disk in this volume group." -ForegroundColor White}
                        $total_vdisk_size_bytes_used += ($disksDetails.entities | Where-Object {$_.uuid -eq $vg_disk.vmdisk_uuid}).stats.controller_user_bytes
                        if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Bytes used for this vg disk: $(($disksDetails.entities | Where-Object {$_.uuid -eq $vg_disk.vmdisk_uuid}).stats.controller_user_bytes)" -ForegroundColor White}
                        $total_vdisk_size_bytes_allocated += ($disksDetails.entities | Where-Object {$_.uuid -eq $vg_disk.vmdisk_uuid}).disk_capacity_in_bytes
                        if ($debugme) {Write-Host "$(get-date) [DEBUG] (vm: $($vm.vm_name)) Bytes allocated for this vg disk: $(($disksDetails.entities | Where-Object {$_.uuid -eq $vg_disk.vmdisk_uuid}).disk_capacity_in_bytes)" -ForegroundColor White}
                    }
                    if ($debugme) {Write-Host "$(get-date) [DEBUG]           VG END*******" -ForegroundColor White}
                }
            }

            $myvarEntityInfo = [ordered]@{
                "vm_name" = $vm.vm_name;
                "uuid" = $vm.uuid;
                "power_state" = $vm.power_state;
                "memory_capacity_in_bytes" = $vm.memory_capacity_in_bytes;
                "num_vcpus" = $vm.num_vcpus;
                "nutanix_guest_tools_status" = $vm.nutanix_guest_tools.enabled;
                "ngt_vss_snapshots" = $vm.nutanix_guest_tools.applications.vss_snapshot;
                "ngt_file_level_restore" = $vm.nutanix_guest_tools.applications.file_level_restore;
                "description" = $vmDetails.description;
                "agent_vm" = $vmDetails.vm_features.AGENT_VM;
                "vdisk_count" = $vmDisks.Count;
                "total_vdisk_size_bytes_allocated" = $total_vdisk_size_bytes_allocated;
                "total_vdisk_size_bytes_used" = $total_vdisk_size_bytes_used
            }
            if ($debugme) {Write-Host "$(get-date) [DEBUG] $($vm.vm_name)) TOTAL BYTES USED = $($total_vdisk_size_bytes_used)" -ForegroundColor White}
            if ($debugme) {Write-Host "$(get-date) [DEBUG] $($vm.vm_name)) TOTAL BYTES ALLOCATED = $($total_vdisk_size_bytes_allocated)" -ForegroundColor White}
        } else {
            $myvarEntityInfo = [ordered]@{
                "vm_name" = $vm.vm_name;
                "uuid" = $vm.uuid;
                "power_state" = $vm.power_state;
                "memory_capacity_in_bytes" = $vm.memory_capacity_in_bytes;
                "num_vcpus" = $vm.num_vcpus;
                "nutanix_guest_tools_status" = $vm.nutanix_guest_tools.enabled;
                "ngt_vss_snapshots" = $vm.nutanix_guest_tools.applications.vss_snapshot;
                "ngt_file_level_restore" = $vm.nutanix_guest_tools.applications.file_level_restore
            }
        }
        #store the results for this entity in our overall result variable
        $myvarResults.Add((New-Object PSObject -Property $myvarEntityInfo)) | Out-Null
        if ($debugme) {Write-Host "$(get-date) [DEBUG] -------------------------------------------" -ForegroundColor White}
    }#end foreach vm

    $myvarResults | Select-Object -Property vm_name,power_state | Sort-Object -Property power_state | Format-Table -AutoSize

    $myvarResults | export-csv -NoTypeInformation unprotected-vms.csv
    Write-Host "$(get-date) [SUCCESS] Exported list to unprotected-vms.csv" -ForegroundColor Cyan

    if ($email -and ($vmList.metadata.count -ge 1))
    {#user wants to send email and we have results
        Write-Host "$(get-date) [INFO] Emailing unprotected-vms.csv..." -ForegroundColor Green
        if ((!$smtp_gateway) -and (!$recipients) -and (!$from))
        {#user hasn't customized the script to enable email
            Write-Host "$(get-date) [ERROR] You must configure the smtp_gateway, recipients and from constants in the script (search for Constants in the script source code)!" -ForegroundColor Red
            Exit
        }
        else 
        {
            $attachment = ".\unprotected-vms.csv"
            Send-MailMessage -From $from -to $recipients -Subject $subject -Body $body -SmtpServer $smtp_gateway -port $smtp_port -Attachments $attachment 
        }
    }


#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($ElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta
	
#endregion