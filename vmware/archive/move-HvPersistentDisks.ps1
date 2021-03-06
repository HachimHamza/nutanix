<#
.SYNOPSIS
  This script is used to migrate Horizon View 7 persistent disks from one desktop pool to another. This can be during a HV server migration, or during a DRP.
.DESCRIPTION
  There are three workflows supported by this script: export, recover and workflow. Export simply creates a csv file containing the list of persistent disk vmdk file names and the Active Directory user they are assigned to.  This csv file can then be used with recover to re-import persistent disks and recreate desktops in a DR pool, or with migrate to remove persistent disks from a given pool and to re-import them into another pool on the same or a different HV server. Note that only disks which are in use are processed. Any unattached disk will be ignored.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER SourceHv
  Hostname of the source Horizon View server. This is a required parameter for the export and migrate workflows.
.PARAMETER TargetHv
  Hostname of the target Horizon View server. This is a required parameter for the migrate and recover workflows.
.PARAMETER TargetvCenter
  Hostname of the vCenter containing the datastore with the persistsent disks vmdk files to be imported or migrated.  This is a required parameter with the migrate and recover workflows.
.PARAMETER PersistentDisksList
  Path and name of the csv file to export to or import from with the recover workflow.
.PARAMETER SourcePool
  Name of the source desktop pool you wish to export or migrate from.  If no pool is specified, it is assumed that all desktop pools must be exporter or migrated.
.PARAMETER TargetPool
  Name of the desktop pool to recover or migrate to.  Only one target desktop pool can be specified.
.PARAMETER Credentials
  Powershell credential object to be used for connecting to source and target Horizon View servers. This can be obtained with Get-Credential otherwise, the script will prompt you for it once.
.PARAMETER UserList
  Comma separated list of users you want to export or migrate. This is to limit the scope of export and migrate to only those users.
.PARAMETER Export
  Specifies you only want to export the list of persistent disks and assigned user to csv.
.PARAMETER Migrate
  Specifies you want to migrate persistent disks from a source HV server to a target HV server and pool. You can use SourcePool and UserList to limit the scope of action.  Note that source and target HV servers can be the same if you only want to migrate to a different desktop pools.
.PARAMETER Recover
  Specifies you want to import from csv a list of persistent disks into a target HV server and pool.  Used for disaster recovery purposes.
.EXAMPLE
  move-HvPersistentDisks.ps1 -sourceHv connection1.local -export -SourcePool pool2
  Export all persistent disks in desktop pool "pool2"
.EXAMPLE
  move-HvPersistentDisks.ps1 -sourceHv connection1.local -export -SourcePool pool1 -UserList "acme\JohnSmith","acme\JaneDoe"
  Export specifed users' persistent disks in desktop pool "pool1"
.EXAMPLE
  move-HvPersistentDisks.ps1 -migrate -sourceHv connection1.local -UserList "acme\JohnSmith","acme\JaneDoe" -TargetHv connection2.local -TargetPool pool1 -TargetvCenter vcenter-new.local
  Migrate persistent disks to a different pool on a different HV server for user "acme\JohnSmith" and "acme\JaneDoe"
.EXAMPLE
  move-HvPersistentDisks.ps1 -recover -sourceHv connection1.local -TargetHv connection2.local -TargetPool dr-pool -TargetvCenter vcenter-new.local -PersistentDisksList c:\source-persistentdisks.csv
  Recover all persistent disks from a csv onto a DR pool
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: August 4th 2017
#>

#region parameters
######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
[CmdletBinding()]
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)][switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $false)] [string]$SourceHv,
	[parameter(mandatory = $false)] [string]$TargetHv,
	[parameter(mandatory = $false)] [string]$TargetvCenter,
	[parameter(mandatory = $false)] [string]$PersistentDisksList,
	[parameter(mandatory = $false)] [string]$SourcePool,
	[parameter(mandatory = $false)] [string]$TargetPool,
	[parameter(mandatory = $false)] [System.Management.Automation.PSCredential]$Credentials,
    [parameter(mandatory = $false)] [string[]]$UserList,
	[parameter(mandatory = $false)] [switch]$Export,
	[parameter(mandatory = $false)] [switch]$Migrate,
	[parameter(mandatory = $false)] [switch]$Recover
)
#endregion

#region functions
########################
##   main functions   ##
########################

#this function is used to output log data
Function OutputLogData 
{
	#input: log category, log message
	#output: text to standard output
<#
.SYNOPSIS
  Outputs messages to the screen and/or log file.
.DESCRIPTION
  This function is used to produce screen and log output which is categorized, time stamped and color coded.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER myCategory
  This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".
.PARAMETER myMessage
  This is the actual message you want to display.
.EXAMPLE
  PS> OutputLogData -mycategory "ERROR" -mymessage "You must specify a cluster name!"
#>
	[CmdletBinding()]
	param
	(
		[string] $category,
		[string] $message
	)

    begin
    {
	    $myvarDate = get-date
	    $myvarFgColor = "Gray"
	    switch ($category)
	    {
		    "INFO" {$myvarFgColor = "Green"}
		    "WARNING" {$myvarFgColor = "Yellow"}
		    "ERROR" {$myvarFgColor = "Red"}
		    "SUM" {$myvarFgColor = "Magenta"}
            "STEP" {$myvarFgColor = "Cyan"}
	    }
    }

    process
    {
	    Write-Host -ForegroundColor $myvarFgColor "$myvarDate [$category] $message"
	    if ($log) {Write-Output "$myvarDate [$category] $message" >>$myvarOutputLogFile}
    }

    end
    {
        Remove-variable category
        Remove-variable message
        Remove-variable myvarDate
        Remove-variable myvarFgColor
    }
}#end function OutputLogData

#this function is used to run an hv query
Function Invoke-HvQuery 
{
	#input: QueryType (see https://vdc-repo.vmware.com/vmwb-repository/dcr-public/f004a27f-6843-4efb-9177-fa2e04fda984/5db23088-04c6-41be-9f6d-c293201ceaa9/doc/index-queries.html), ViewAPI service object
	#output: query result object
<#
.SYNOPSIS
  Runs a Horizon View query.
.DESCRIPTION
  Runs a Horizon View query.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER QueryType
  Type of query (see https://vdc-repo.vmware.com/vmwb-repository/dcr-public/f004a27f-6843-4efb-9177-fa2e04fda984/5db23088-04c6-41be-9f6d-c293201ceaa9/doc/index-queries.html)
.PARAMETER ViewAPIObject
  View API service object.
.EXAMPLE
  PS> Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI
#>
	[CmdletBinding()]
	param
	(
      [string]
        [ValidateSet('ADUserOrGroupSummaryView','ApplicationIconInfo','ApplicationInfo','DesktopSummaryView','EntitledUserOrGroupGlobalSummaryView','EntitledUserOrGroupLocalSummaryView','FarmHealthInfo','FarmSummaryView','GlobalEntitlementSummaryView','MachineNamesView','MachineSummaryView','PersistentDiskInfo','PodAssignmentInfo','RDSServerInfo','RDSServerSummaryView','RegisteredPhysicalMachineInfo','SessionGlobalSummaryView','SessionLocalSummaryView','TaskInfo','UserHomeSiteInfo')]
        $QueryType,
        [VMware.Hv.Services]
        $ViewAPIObject
	)

    begin
    {
	    
    }

    process
    {
	    $serviceQuery = New-Object "Vmware.Hv.QueryServiceService"
        $query = New-Object "Vmware.Hv.QueryDefinition"
        $query.queryEntityType = $QueryType
        $query.MaxPageSize = 1000
        if ($query.QueryEntityType -eq 'PersistentDiskInfo') {
            $query.Filter = New-Object VMware.Hv.QueryFilterNotEquals -property @{'memberName'='storage.virtualCenter'; 'value' =$null}
        }
        if ($query.QueryEntityType -eq 'ADUserOrGroupSummaryView') {
            try {$object = $serviceQuery.QueryService_Create($ViewAPIObject,$query)}
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        } else {
            try {$object = $serviceQuery.QueryService_Query($ViewAPIObject,$query)}
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        }
    }

    end
    {
        if (!$object) {
            OutputLogData -category "ERROR" -message "The View API query did not return any data... Exiting!"
            exit
        }
        return $object
    }
}#end function Invoke-HvQuery

#this function is used to get the file name and assigned user for a persistent disk
Function Get-PersistentDiskInfo 
{
	#input: PersistentDisk, ViewAPI service object
	#output: PersistentDiskInfo
<#
.SYNOPSIS
  Runs a Horizon View query.
.DESCRIPTION
  Runs a Horizon View query.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER PersistentDisk
  Persistent Disk object.
.PARAMETER ViewAPI
  View API service object.
.EXAMPLE
  PS> Invoke-HvQuery -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
#>
	[CmdletBinding()]
	param
	(
        $PersistentDisk,
        $ViewAPI
	)

    begin
    {
	    
    }

    process
    {
        $PersistentDiskName = $PersistentDisk.General.Name #this is the vmdk file name
        $userId = $PersistentDisk.General.User #this is the id of the assigned user
                    
        #we need to retrieve the user name from that id
        OutputLogData -category "INFO" -message "Grabbing the Active Directory users from the Horizon View server..."
        $serviceADUserOrGroup = New-Object "Vmware.Hv.ADUserOrGroupService" #create the required object to run methods on
        try {$user = $serviceADUserOrGroup.ADUserOrGroup_Get($ViewAPI,$userId)} #run the get method on that object filtering on the userid
        catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $AssignedUser = $user.Base.DisplayName #store the display name in a variable

        #let's get the datastore and full path for that persistent disk
        $PersistentDiskDatastore = $PersistentDisk.Storage.DatastoreName

        #we now need to figure out the path for that persistent disk, which requires to know the datastore id
        $vCenterId = $PersistentDisk.Storage.VirtualCenter #first we need the vCenter Id
        $serviceDesktop = New-Object "VMware.Hv.DesktopService" #we need a Desktop service object
        OutputLogData -category "INFO" -message "Grabbing the desktop pools from the Horizon View server..."
        try {$DesktopGet = $serviceDesktop.Desktop_Get($ViewAPI,$PersistentDisk.General.Desktop)} #we now retrieve the desktop object that persistent disk belongs to
        catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $HostOrClusterId = $DesktopGet.AutomatedDesktopData.VirtualCenterProvisioningSettings.VirtualCenterProvisioningData.HostOrCluster #we now grab the HostOrCluster Id that desktop pool provisions to
        $serviceDatastore = New-Object "VMware.Hv.DatastoreService" #we now need a Datastore service object
        OutputLogData -category "INFO" -message "Grabbing the datastores from the Horizon View server..."
        try {$datastores = $serviceDatastore.Datastore_ListDatastoresByHostOrCluster($ViewAPI,$HostOrClusterId)} #we grab the list of datastores available for that HostOrCluster
        catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        if (!($datastoreId = ($datastores | where {$_.DatastoreData.Name -eq $PersistentDiskDatastore}).Id)) {OutputLogData -category "ERROR" -message "Could not figure out the datastore Id! Exiting."; Exit} #we grab the datastore Id where our persistent disk is

        $serviceVirtualDisk = New-Object "Vmware.Hv.VirtualDiskService" #create the required object to run methods on
        OutputLogData -category "INFO" -message "Grabbing the list of virtual disks on the datastore..."
        try {$VirtualDisks = $serviceVirtualDisk.VirtualDisk_List($ViewAPI,$vCenterId,$datastoreId)} #retrieving the list of virtual disks from the vCenter server
        catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}

        $PersistentDiskPath = ($VirtualDisks.Data | where {($_.Name -eq $PersistentDiskName) -and ($_.Attached -eq $true)} | select Path).Path

        $PersistentDiskInfo = @{"PersistentDiskName" = $PersistentDiskName;"AssignedUser" = $AssignedUser;"Datastore" = $PersistentDiskDatastore;"Path" = $PersistentDiskPath} #we build the information for that specific disk
    }

    end
    {
        return $PersistentDiskInfo
    }
}#end function Get-PersistentDiskInfo

#this function is used to get the file name and assigned user for a persistent disk
Function Invoke-ExportWorkflow 
{
	#input: ViewAPI service object
	#output: PersistentDisksCsv
<#
.SYNOPSIS
  Runs the export workflow which creates a variable ready to be exported to csv which contains the list of persistent disk file names and assigned users for the given pool, user list of HV server.
.DESCRIPTION
  Runs the export workflow which creates a variable ready to be exported to csv which contains the list of persistent disk file names and assigned users for the given pool, user list of HV server.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER ViewAPI
  View API service object.
.EXAMPLE
  PS> Invoke-ExportWorkFlow -ViewAPI $ViewAPI
#>
	[CmdletBinding()]
	param
	(
        $ViewAPI
	)

    begin
    {
	    
    }

    process
    {       
        #retrieve list of persistent disks
        OutputLogData -category "INFO" -message "Retrieving the list of persistent disks..."
        $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI

        #foreach disk, get the disk name and assigned user name
        OutputLogData -category "INFO" -message "Figuring out disk names and assigned user name..."
        [System.Collections.ArrayList]$PersistentDisksCsv = New-Object System.Collections.ArrayList($null) #we'll use this variable to collect persistent disk information
        if ($SourcePool) {$Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI} #let's grab all the desktop pools
        if ($UserList) {$ADUserOrGroups = Invoke-HvQuery -QueryType ADUserOrGroupSummaryView -ViewAPIObject $ViewAPI} #let's grab AD users

        $serviceQuery = New-Object "Vmware.Hv.QueryServiceService"
        ForEach ($PersistentDisk in ($PersistentDisks.Results | where {($_.General.User -ne $null) -and ($_.General.Status -eq "IN_USE")})) { #process each disk which has an assigned user and is not detached
            if ($SourcePool -and $UserList) {#both a source pool and userlist has been specified
                $DesktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $SourcePool}).Id #we grab the ID of the desktop pool we're interested in
                if ($PersistentDisk.General.Desktop.Id -eq $DesktopId.Id) { #check if that persistent disk belongs to the desktop pool we are interested in
                    ForEach ($User in $UserList) { #now let's see if that disk belongs to one of the users we have specified
                        while ($ADUserOrGroups.Results -ne $null) {
                            if (!($UserId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $User}).Id)) { #grab the user ID from the name
                                #couldn't find our userId, let's fetch the next page of AD objects
                                if ($ADUserOrGroups.id -eq $null) {break}
                                try {$ADUserOrGroups = $serviceQuery.QueryService_GetNext($ViewAPI,$ADUserOrGroups.id)}
                                catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
                            } else {break} #we found our user, let's get out of this loop
                        }
                        if ($PersistentDisk.General.User.Id -eq $UserId.Id) { #do we have a match?
                            $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI #grab the details pf the persistent disk
                            $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
                        }
                    }  
                }
            } ElseIf ($SourcePool) { #if a pool has been specified, only export this disk information if it is attached to a desktop in that pool
                $DesktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $SourcePool}).Id #we grab the ID of the desktop pool we're interested in
                if ($PersistentDisk.General.Desktop.Id -eq $DesktopId.Id) { #check if that persistent disk belongs to the desktop pool we are interested in
                    $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI #grab the details pf the persistent disk
                    $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
                }
            } ElseIf ($UserList) { #if a user list has been specified, only export that disk information if the disk is assigned to a user in that list
                ForEach ($User in $UserList) { #now let's see if that disk belongs to one of the users we have specified
                    $UserId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $User}).Id
                    if ($PersistentDisk.General.User.Id -eq $UserId.Id) { #grab the user ID from the name
                        $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI #grab the details pf the persistent disk
                        $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
                    }
                }
            } else {
                $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
                $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
            }
        }#end foreach PersistentDisk
    }

    end
    {
        return $PersistentDisksCsv
    }
}#end function Invoke-ExportWorkflow

#this function is used to get the file name and assigned user for a persistent disk
Function Invoke-RecoverWorkflow 
{
	#input: ViewAPI service object, PersistentDisksCsv variable
	#output: null
<#
.SYNOPSIS
  Imports all given persistent disks into the targetHv server and targetPool, then recreates VMs in that pool.
.DESCRIPTION
  Imports all given persistent disks into the targetHv server and targetPool, then recreates VMs in that pool.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER ViewAPI
  View API service object.
.PARAMETER PersistentDisksCsv
.EXAMPLE
  PS> Invoke-RecoverWorkFlow -ViewAPI $ViewAPI -PersistentDisksCsv $PersistentDisksCsv
#>
	[CmdletBinding()]
	param
	(
        $ViewAPI,
        $PersistentDisksCsv
	)

    begin
    {
	    
    }

    process
    {
        #setting things up
        $servicePersistentDisk = New-Object "Vmware.Hv.PersistentDiskService" #create the required object to run methods on
        $serviceVirtualDisk = New-Object "Vmware.Hv.VirtualDiskService" #create the required object to run methods on
        $Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI #retrieving the list of desktop pools
        $ADUserOrGroups = Invoke-HvQuery -QueryType ADUserOrGroupSummaryView -ViewAPIObject $ViewAPI #retrieving the list of AD users
        $AccessGroupId = ($Desktops.Results.DesktopSummaryData | where {$_.Name -eq $TargetPool} | select -Property AccessGroup).AccessGroup #figuring out the access group id for that desktop pool
        $desktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $TargetPool}).Id #figuring out the desktop id for the pool

        #import disks & recreate vms
        OutputLogData -category "INFO" -message "Importing persistent disks in $TargetHv..."
        if (!($vCenterId = ($ViewAPI.VirtualCenter.VirtualCenter_List() | where {$_.ServerSpec.ServerName -eq $TargetvCenter} | Select -Property Id).Id)) { #figuring out the object id for the specified vCenter server
            OutputLogData -category "ERROR" -message "Could not find vCenter $TargetvCenter!"
            Exit
        }
        
       
        ForEach ($PersistentDisk in $PersistentDisksCsv) { #let's process each disk
            #we now need to figure out the path for that persistent disk, which requires to know the datastore id
            $serviceDesktop = New-Object "VMware.Hv.DesktopService" #we need a Desktop service object
            OutputLogData -category "INFO" -message "Grabbing the desktop pools from the Horizon View server..."
            try {$DesktopGet = $serviceDesktop.Desktop_Get($ViewAPI,$desktopId)} #we now retrieve the desktop object that persistent disk belongs to
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
            $HostOrClusterId = $DesktopGet.AutomatedDesktopData.VirtualCenterProvisioningSettings.VirtualCenterProvisioningData.HostOrCluster #we now grab the HostOrCluster Id that desktop pool provisions to
            $serviceDatastore = New-Object "VMware.Hv.DatastoreService" #we now need a Datastore service object
            OutputLogData -category "INFO" -message "Grabbing the datastores from the Horizon View server..."
            try {$datastores = $serviceDatastore.Datastore_ListDatastoresByHostOrCluster($ViewAPI,$HostOrClusterId)} #we grab the list of datastores available for that HostOrCluster
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
            if (!($datastoreId = ($datastores | where {$_.DatastoreData.Name -eq $PersistentDisk.Datastore}).Id)) {OutputLogData -category "ERROR" -message "Could not figure out the datastore Id! Exiting."; Exit} #we grab the datastore Id where our persistent disk is

            try {$VirtualDisks = $serviceVirtualDisk.VirtualDisk_List($ViewAPI,$vCenterId,$datastoreId)} #retrieving the list of virtual disks from the vCenter server
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}

            $virtualDiskId = ($VirtualDisks | where {$_.Data.Name -eq $PersistentDisk.PersistentDiskName}).Id #figuring out the virtual disk id
            if (!$virtualDiskId) {OutputLogData -category "WARNING" -message "Could not find persistent disk $($PersistentDisk.PersistentDiskName) in $($PersistentDisk.Path) on $TargetvCenter. Skipping."; Next}
            if ($virtualDiskId.Count -gt 1) {OutputLogData -category "WARNING" -message "There is more than one disk with the same name available on the target vCenter server. Can't import persistent disk $($PersistentDisk.PersistentDiskName). Skipping."; Next}
            
            $serviceQuery = New-Object "Vmware.Hv.QueryServiceService"
            while ($ADUserOrGroups.Results -ne $null) {
                if (!($UserId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $PersistentDisk.AssignedUser}).Id)) { #figuring out the assigned user id
                    #couldn't find our userId, let's fetch the next page of AD objects
                    if ($ADUserOrGroups.id -eq $null) {break}
                    try {$ADUserOrGroups = $serviceQuery.QueryService_GetNext($ViewAPI,$ADUserOrGroups.id)}
                    catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
                } else {break} #we found our user, let's get out of this loop
            }

            if (!$userId) {OutputLogData -category "WARNING" -message "Could not find user $($PersistentDisk.AssignedUser). Can't import persistent disk $($PersistentDisk.PersistentDiskName). Skipping."; Next}
            
            $PersistentDiskSpec = New-Object "Vmware.Hv.PersistentDiskSpec" #building the persistent disk object specification
            $PersistentDiskSpec.VirtualDisk = $virtualDiskId
            $PersistentDiskSpec.AccessGroup = $AccessGroupId
            $PersistentDiskSpec.User = $userId
            $PersistentDiskSpec.Desktop = $desktopId #this is the desktop pool

            OutputLogData -category "INFO" -message "Importing persistent disk $($PersistentDisk.PersistentDiskName)..."
            try{$importedPersistentDiskId = $servicePersistentDisk.PersistentDisk_Create($ViewAPI,$PersistentDiskSpec)} #import the disk
            catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
            OutputLogData -category "INFO" -message "Successfully Imported disk $($PersistentDisk.PersistentDiskName) with id $($importedPersistentDiskId.Id) and assigned it to user $($PersistentDisk.AssignedUser)."
            OutputLogData -category "INFO" -message "Recreating VM from persistent disk $($PersistentDisk.PersistentDiskName)..."
            try {$machineId = $servicePersistentDisk.PersistentDisk_RecreateMachine($ViewAPI,$importedPersistentDiskId,$null)} #recreate the vm
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
            OutputLogData -category "INFO" -message "Successfully Created VM $($machineId.Id)"
        }
    }

    end
    {
        
    }
}#end function Invoke-RecoverWorkflow

#endregion


#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}

#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 08/04/2017 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\move-HvPersistentDisks.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}

#region Load/Install VMware.PowerCLI
if (!(Get-Module VMware.PowerCLI)) {
    try {
        Write-Host "$(get-date) [INFO] Loading VMware.PowerCLI module..." -ForegroundColor Green
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
        Write-Host "$(get-date) [SUCCESS] Loaded VMware.PowerCLI module" -ForegroundColor Cyan
    }
    catch { 
        Write-Host "$(get-date) [WARNING] Could not load VMware.PowerCLI module!" -ForegroundColor Yellow
        try {
            Write-Host "$(get-date) [INFO] Installing VMware.PowerCLI module..." -ForegroundColor Green
            Install-Module -Name VMware.PowerCLI -Scope CurrentUser -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Installed VMware.PowerCLI module" -ForegroundColor Cyan
            try {
                Write-Host "$(get-date) [INFO] Loading VMware.PowerCLI module..." -ForegroundColor Green
                Import-Module VMware.VimAutomation.Core -ErrorAction Stop
                Write-Host "$(get-date) [SUCCESS] Loaded VMware.PowerCLI module" -ForegroundColor Cyan
            }
            catch {throw "$(get-date) [ERROR] Could not load the VMware.PowerCLI module : $($_.Exception.Message)"}
        }
        catch {throw "$(get-date) [ERROR] Could not install the VMware.PowerCLI module. Install it manually from https://www.powershellgallery.com/items?q=powercli&x=0&y=0 : $($_.Exception.Message)"} 
    }
}

#check PowerCLI version
if ((Get-Module -Name VMware.VimAutomation.Core).Version.Major -lt 10) {
    try {Update-Module -Name VMware.PowerCLI -Scope CurrentUser -ErrorAction Stop} catch {throw "$(get-date) [ERROR] Could not update the VMware.PowerCLI module : $($_.Exception.Message)"}
    throw "$(get-date) [ERROR] Please upgrade PowerCLI to version 10 or above by running the command 'Update-Module VMware.PowerCLI' as an admin user"
}
#endregion

#region module BetterTls
if (!(Get-Module -Name BetterTls)) {
    Write-Host "$(get-date) [INFO] Importing module 'BetterTls'..." -ForegroundColor Green
    try
    {
        Import-Module -Name BetterTls -ErrorAction Stop
        Write-Host "$(get-date) [SUCCESS] Imported module 'BetterTls'!" -ForegroundColor Cyan
    }#end try
    catch #we couldn't import the module, so let's install it
    {
        Write-Host "$(get-date) [INFO] Installing module 'BetterTls' from the Powershell Gallery..." -ForegroundColor Green
        try {Install-Module -Name BetterTls -Scope CurrentUser -ErrorAction Stop}
        catch {throw "$(get-date) [ERROR] Could not install module 'BetterTls': $($_.Exception.Message)"}

        try
        {
            Import-Module -Name BetterTls -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Imported module 'BetterTls'!" -ForegroundColor Cyan
        }#end try
        catch #we couldn't import the module
        {
            Write-Host "$(get-date) [ERROR] Unable to import the module BetterTls : $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "$(get-date) [WARNING] Please download and install from https://www.powershellgallery.com/packages/BetterTls/0.1.0.0" -ForegroundColor Yellow
            Exit
        }#end catch
    }#end catch
}
Write-Host "$(get-date) [INFO] Disabling Tls..." -ForegroundColor Green
try {Disable-Tls -Tls -Confirm:$false -ErrorAction Stop} catch {throw "$(get-date) [ERROR] Could not disable Tls : $($_.Exception.Message)"}
Write-Host "$(get-date) [INFO] Enabling Tls 1.2..." -ForegroundColor Green
try {Enable-Tls -Tls12 -Confirm:$false -ErrorAction Stop} catch {throw "$(get-date) [ERROR] Could not enable Tls 1.2 : $($_.Exception.Message)"}
#endregion


#endregion

#region variables
#misc variables
$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
$myvarOutputLogFile += "OutputLog.log"
#endregion

#region parameters validation
############################################################################
# command line arguments initialization
############################################################################	
#let's initialize parameters if they haven't been specified
if ($SourceHv -and ($SourceHv.Count -gt 1)) {OutputLogData -category "ERROR" -message "You can only specify a single source Horizon View server!"; Exit}
if ($TargetHv -and ($TargetHv.Count -gt 1)) {OutputLogData -category "ERROR" -message "You can only specify a single target Horizon View server!"; Exit}
if ($SourcePool -and ($SourcePool.Count -gt 1)) {OutputLogData -category "ERROR" -message "You can only specify a single source desktop pool!"; Exit}
if ($TargetPool -and ($TargetPool.Count -gt 1)) {OutputLogData -category "ERROR" -message "You can only specify a single target desktop pool!"; Exit}
if ($TargetvCenter -and ($TargetvCenter.Count -gt 1)) {OutputLogData -category "ERROR" -message "You can only specify a single target vCenter server!"; Exit}
#endregion



#region processing
	
    #region workflow 1: export
    if ($Export) {
        OutputLogData -category "STEP" -message "STARTING THE EXPORT WORKFLOW..."
        #check we have the required input
        if (!$SourceHv) {$SourceHv = Read-Host "Enter the name of the Horizon View server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        
        #connect to source hv
        OutputLogData -category "INFO" -message "Connecting to the SOURCE Horizon View server $SourceHv..."
        try {Connect-HVServer -Server $SourceHv -Credential $Credentials -ErrorAction Stop | Out-Null} #connecting to the source Horizon View server
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to Horizon View server $SourceHv"
        
        $PersistentDisksCsv = Invoke-ExportWorkflow -ViewAPI $ViewAPI #grab our list of persistent disks
        if (!$PersistentDisksCsv) {OutputLogData -category "ERROR" -message "There is no disk matching the specified criteria. Exiting."; Disconnect-HVServer -Force * -Confirm:$false; Exit}

        #export results to csv
        if (!$PersistentDisksList) {$PersistentDisksList = "$($SourceHv)-persistentDisks.csv"}
        OutputLogData -category "INFO" -message "Exporting results to csv file $PersistentDisksList ..."
        $PersistentDisksCsv | Export-Csv -NoTypeInformation $PersistentDisksList
        
        #disconnect from source hv
        OutputLogData -category "INFO" -message "Disconnecting from the SOURCE Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false

        OutputLogData -category "STEP" -message "COMPLETED EXPORT WORKFLOW."
    }
    #endregion

    #region workflow 2: recover
    if ($Recover) {
        OutputLogData -category "STEP" -message "STARTING THE RECOVER WORKFLOW..."
        #checking we have the required input
        if (!$PersistentDisksList) {$PersistentDisksList = Read-Host "Please enter the path of the csv file containing the list of persistent disks to import"}
        
        #read from csv file
        if (!(Test-Path $PersistentDisksList)) {OutputLogData -category "ERROR" -message "$PersistentDisksList cannot be found. Please enter a valid csv file"; Exit}
        OutputLogData -category "INFO" -message "Importing persistent disks list from $PersistentDisksList..."
        $PersistentDisksCsv = Import-Csv $PersistentDisksList       
        if (!$PersistentDisksCsv) {OutputLogData -category "ERROR" -message "There is no disk matching the specified criteria. Exiting."; Disconnect-HVServer -Force * -Confirm:$false; Exit}

        #checking we have the required input
        if (!$TargetHv) {$TargetHv = Read-Host "Please enter the name of the target Horizon View Server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        if (!$TargetPool) {$TargetPool = Read-Host "Please enter the name of the target desktop pool"}
        if (!$TargetvCenter) {$TargetvCenter = Read-Host "Please enter the name of the vCenter server from which the persistent disks must be imported"}

        #connect to target hv
        OutputLogData -category "INFO" -message "Connecting to the TARGET Horizon View server $TargetHv..."
        try {Connect-HVServer -Server $TargetHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to target Horizon View server $TargetHv"

        Invoke-RecoverWorkflow -ViewAPI $ViewAPI -PersistentDisksCsv $PersistentDisksCsv

        #disconnect from target hv
        OutputLogData -category "INFO" -message "Disconnecting from the target Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false

        OutputLogData -category "STEP" -message "COMPLETED THE RECOVER WORKFLOW."
    }
    #endregion

    #region workflow 3: migrate
    if ($Migrate) {
        OutputLogData -category "STEP" -message "STARTING THE MIGRATE WORKFLOW..."
        
        #check we have the required input
        if (!$SourceHv) {$SourceHv = Read-Host "Enter the name of the Horizon View server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        if (!$TargetHv) {$TargetHv = Read-Host "Please enter the name of the target Horizon View Server"}
        if (!$TargetPool) {$TargetPool = Read-Host "Please enter the name of the target desktop pool"}
        if (!$TargetvCenter) {$TargetvCenter = Read-Host "Please enter the name of the vCenter server from which the persistent disks must be imported"}
        
        #region initial checks
        OutputLogData -category "STEP" -message "PERFORMING PRE-CHECKS..."

        #connect to source hv
        OutputLogData -category "INFO" -message "Connecting to the SOURCE Horizon View server $SourceHv..."
        try {Connect-HVServer -Server $SourceHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to source Horizon View server $SourceHv"
        
        $PersistentDisksCsv = Invoke-ExportWorkflow -ViewAPI $ViewAPI
        if (!$PersistentDisksCsv) {OutputLogData -category "ERROR" -message "There is no disk matching the specified criteria. Exiting."; Disconnect-HVServer -Force * -Confirm:$false; Exit}

        $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI #checking for the persistent disk Id
        Foreach ($PersistentDisk in $PersistentDisksCsv) {
            OutputLogData -category "INFO" -message "Checking for multiple persistent disk Ids for $($PersistentDisk.PersistentDiskName)..."
            if ($SourcePool) { #make sure we filter on the desktop source pool to avoid getting multiple disk Ids
                #figure out the source desktop pool id
                $Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI
                $DesktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $SourcePool}).Id
                #filter on both the disk name and the desktop pool
                $PersistentDiskId = ($PersistentDisks.Results | where {($_.General.Name -eq $PersistentDisk.PersistentDiskName) -and ($_.General.Desktop.Id -eq $DesktopId.Id) -and ($_.General.User -ne $null)}).Id #grab the disk id
            } else {
                $PersistentDiskId = ($PersistentDisks.Results | where {($_.General.Name -eq $PersistentDisk.PersistentDiskName) -and ($_.General.User -ne $null)}).Id #grab the disk id
            }
            if ($PersistentDiskId.Count -ne 1) {OutputLogData -category "ERROR" -message "Somehow there is more than one persistent disk id to remove. Exiting before we get an APÏ method error."; Exit}
        }

        #disconnect from source hv
        OutputLogData -category "INFO" -message "Disconnecting from the source Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false

        #connect to target hv
        OutputLogData -category "INFO" -message "Connecting to the TARGET Horizon View server $TargetHv..."
        try {Connect-HVServer -Server $TargetHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData
        OutputLogData -category "INFO" -message "Connected to target Horizon View server $TargetHv"

        #check for each disk that we can find the user and that there is only one disk with that name
        $servicePersistentDisk = New-Object "Vmware.Hv.PersistentDiskService" #create the required object to run methods on
        $serviceVirtualDisk = New-Object "Vmware.Hv.VirtualDiskService" #create the required object to run methods on
        $Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI #retrieving the list of desktop pools
        $ADUserOrGroups = Invoke-HvQuery -QueryType ADUserOrGroupSummaryView -ViewAPIObject $ViewAPI #retrieving the list of AD users
        if (!($AccessGroupId = ($Desktops.Results.DesktopSummaryData | where {$_.Name -eq $TargetPool} | select -Property AccessGroup).AccessGroup)) {OutputLogData -category "ERROR" -message "Can't figure out the access group for the target desktop pool $TargetPool."; Exit} #figuring out the access group id for that desktop pool
        if (!($desktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $TargetPool}).Id)) {OutputLogData -category "ERROR" -message "Can't find the desktop poool $TargetPool on $TargetHv. Exiting."; Exit} #figuring out the desktop id for the pool
        if (!($vCenterId = ($ViewAPI.VirtualCenter.VirtualCenter_List() | where {$_.ServerSpec.ServerName -eq $TargetvCenter} | Select -Property Id).Id)) { #figuring out the object id for the specified vCenter server
            OutputLogData -category "ERROR" -message "Could not find vCenter $TargetvCenter!"
            Exit
        }

        #we now need to figure out the path for that persistent disk, which requires to know the datastore id
        $serviceDesktop = New-Object "VMware.Hv.DesktopService" #we need a Desktop service object
        OutputLogData -category "INFO" -message "Grabbing the desktop pools from the Horizon View server..."
        try {$DesktopGet = $serviceDesktop.Desktop_Get($ViewAPI,$desktopId)} #we now retrieve the desktop object that persistent disk belongs to
        catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $HostOrClusterId = $DesktopGet.AutomatedDesktopData.VirtualCenterProvisioningSettings.VirtualCenterProvisioningData.HostOrCluster #we now grab the HostOrCluster Id that desktop pool provisions to
        $serviceDatastore = New-Object "VMware.Hv.DatastoreService" #we now need a Datastore service object
        OutputLogData -category "INFO" -message "Grabbing the datastores from the Horizon View server..."
        try {$datastores = $serviceDatastore.Datastore_ListDatastoresByHostOrCluster($ViewAPI,$HostOrClusterId)} #we grab the list of datastores available for that HostOrCluster
        catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        
        ForEach ($PersistentDisk in $PersistentDisksCsv) {
            $ADUserOrGroups = Invoke-HvQuery -QueryType ADUserOrGroupSummaryView -ViewAPIObject $ViewAPI #retrieving the list of AD users
            if (!($datastoreId = ($datastores | where {$_.DatastoreData.Name -eq $PersistentDisk.Datastore}).Id)) {OutputLogData -category "ERROR" -message "Could not figure out the datastore Id! Exiting."; Exit} #we grab the datastore Id where our persistent disk is
            OutputLogData -category "INFO" -message "Grabbing virtual disks on datastore $($PersistentDisk.Datastore)..."
            try {$VirtualDisks = $serviceVirtualDisk.VirtualDisk_List($ViewAPI,$vCenterId,$datastoreId)} #retrieving the list of virtual disks from the vCenter server
            catch {OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
            if (!($virtualDiskId = ($VirtualDisks | where {($_.Data.Name -eq $PersistentDisk.PersistentDiskName) -and ($_.Data.Path -eq $PersistentDisk.Path)}).Id)) {OutputLogData -category "ERROR" -message "Can't find persistent disk $($PersistentDisk.PersistentDiskName) on $TargetvCenter. Exiting."; Exit} #figuring out the virtual disk id
            if ($virtualDiskId.Count -gt 1) {OutputLogData -category "ERROR" -message "There is more than one disk with the same name available on the target vCenter server. Can't import persistent disk $($PersistentDisk.PersistentDiskName). Exiting."; Exit}
            
            $serviceQuery = New-Object "Vmware.Hv.QueryServiceService"
            while ($ADUserOrGroups.Results -ne $null) {
                if (!($userId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $PersistentDisk.AssignedUser}).Id)) { #grab the user ID from the name
                    #couldn't find our userId, let's fetch the next page of AD objects
                    if ($ADUserOrGroups.id -eq $null) {break}
                    try {$ADUserOrGroups = $serviceQuery.QueryService_GetNext($ViewAPI,$ADUserOrGroups.id)}
                    catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
                } else {break} #we found our user, let's get out of this loop
            }

            if (!$userId) {OutputLogData -category "ERROR" -message "Could not find user $($PersistentDisk.AssignedUser). Can't import persistent disk $($PersistentDisk.PersistentDiskName). Exiting."; Exit} #figuring out the assigned user id
        }

        #disconnect from target hv
        OutputLogData -category "INFO" -message "Disconnecting from the Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false

        OutputLogData -category "STEP" -message "COMPLETED PRE-CHECKS."
        #endregion

        #region process source

        #connect to source hv
        OutputLogData -category "STEP" -message "PROCESSING SOURCE..."
        OutputLogData -category "INFO" -message "Connecting to the SOURCE Horizon View server $SourceHv..."
        try {Connect-HVServer -Server $SourceHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to source Horizon View server $SourceHv"

        #delete machine and archive/detach persistent disk. This is because primary persistent disks can't be archived directly.
        $serviceMachineService = New-Object "VMware.Hv.MachineService" #we will use that service to make our API method call
        ForEach ($PersistentDisk in $PersistentDisksCsv) {
            $MachineNamesView = Invoke-HvQuery -QueryType MachineNamesView -ViewAPIObject $ViewAPI #grab the VMs/desktops
            if ($SourcePool) { #has a source pool been specified?
                $MachineId = ($MachineNamesView.Results | where {($_.NamesData.DesktopName -eq $SourcePool) -and ($_.NamesData.UserName -eq $PersistentDisk.AssignedUser)}).Id #keep only the machine that matches the desktop pool and assigned user
            } else {
                $MachineId = ($MachineNamesView.Results | where {$_.NamesData.UserName -eq $PersistentDisk.AssignedUser}).Id #otherwise we keep only the machine assigned to our user
            }
            #prepare the specification for deleting a machine
            $MachineDeleteSpec = New-Object "Vmware.Hv.MachineDeleteSpec"
            $MachineDeleteSpec.DeleteFromDisk = $true
            $MachineDeleteSpec.ArchivePersistentDisk = $true
            OutputLogData -category "INFO" -message "Deleting virtual machine assigned to user $($PersistentDisk.AssignedUser) and archiving persistent disk $($PersistentDisk.PersistentDiskName)"
            try {$serviceMachineService.Machine_Delete($ViewAPI,$MachineId,$MachineDeleteSpec)} #calling the machine delete API method
            catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        }
        
        #remove persistent disks from source hv without deleting them from the datastore
        $servicePersistentDisk = New-Object "VMware.Hv.PersistentDiskService" #we will use that service to make our API method call
        ForEach ($PersistentDisk in $PersistentDisksCsv) {
            $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI #grab details on our persistent disks
            Do { #create a loop that waits until our disk has been archived so that we may remove it from HV
                OutputLogData -category "INFO" -message "Waiting for $($PersistentDisk.PersistentDiskName) to finish archiving..."
                Start-Sleep -Seconds 15
                $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI
                OutputLogData -category "INFO" -message "Persistent disk status is $(($PersistentDisks.Results | where {$_.General.Name -eq $PersistentDisk.PersistentDiskName}).General.Status)..."
            } While (($PersistentDisks.Results | where {$_.General.Name -eq $PersistentDisk.PersistentDiskName}).General.Status -eq "ARCHIVING")
            if ($SourcePool) { #make sure we filter on the desktop source pool to avoid getting multiple disk Ids
                #figure out the source desktop pool id
                $Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI
                $DesktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $SourcePool}).Id
                #filter on both the disk name and the desktop pool
                $PersistentDiskId = ($PersistentDisks.Results | where {($_.General.Name -eq $PersistentDisk.PersistentDiskName) -and ($_.General.Desktop.Id -eq $DesktopId.Id) -and ($_.General.User -ne $null)}).Id #grab the disk id
            } else {
                $PersistentDiskId = ($PersistentDisks.Results | where {($_.General.Name -eq $PersistentDisk.PersistentDiskName) -and ($_.General.User -ne $null)}).Id #grab the disk id
            }
            if ($PersistentDiskId.Count -ne 1) {OutputLogData -category "ERROR" -message "Somehow there is more than one persistent disk id to remove. Exiting before we get an APÏ method error."; Exit}
            #create the disk delete specification required by the API method
            $PersistentDiskDeleteSpec = New-Object "Vmware.Hv.PersistentDiskDeleteSpec"
            $PersistentDiskDeleteSpec.DeleteFromDisk = $false #important to not delete the disks from the datastore
            OutputLogData -category "INFO" -message "Removing persistent disk $($PersistentDisk.PersistentDiskName) from $SourceHv..."
            try{$servicePersistentDisk.PersistentDisk_Delete($ViewAPI,$PersistentDiskId,$PersistentDiskDeleteSpec)} #make the API method call
            catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        }
        
        #disconnect from source hv
        OutputLogData -category "INFO" -message "Disconnecting from the source Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false
        OutputLogData -category "INFO" -message "We're done with exporting persistent disks from the source, now let's process importing on the target Horizon View server..."
        OutputLogData -category "STEP" -message "COMPLETED PROCESSING SOURCE."
        #endregion

        #region process target
        OutputLogData -category "STEP" -message "PROCESSING TARGET..."
        #recover vms on target
        
        #connect to target hv
        OutputLogData -category "INFO" -message "Connecting to the TARGET Horizon View server $TargetHv..."
        try {Connect-HVServer -Server $TargetHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData
        OutputLogData -category "INFO" -message "Connected to target Horizon View server $TargetHv"

        Invoke-RecoverWorkflow -ViewAPI $ViewAPI -PersistentDisksCsv $PersistentDisksCsv
        
        #disconnect from target hv
        OutputLogData -category "INFO" -message "Disconnecting from the target Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false
        OutputLogData -category "STEP" -message "COMPLETED PROCESSING TARGET."
        #endregion

        OutputLogData -category "STEP" -message "COMPLETED THE MIGRATE WORKFLOW."
    }
    #endregion

#endregion



#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
	OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar* -ErrorAction SilentlyContinue
	Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
	Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
	Remove-Variable log -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion
