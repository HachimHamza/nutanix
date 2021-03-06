################################################################################
# Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
# Description:  see help below
# Revision history: see history below
################################################################################

######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
#this param line MUST BE FIRST in the script
param
(
	[switch] $help,
	[switch] $log,
	[string] $vcenter,
	[string] $cluster,
	[string] $hostgroup,
	[string] $vmgroup,
	[string] $vmtohost,
	[switch] $should,
	[switch] $must,
	[switch] $lb,
	[string] $hosts,
	[string] $vms,
	[string] $folder,
    [switch] $debugme
)

# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}

########################
##   main functions   ##
########################

#this function is used to output log data
Function OutputLogData {
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
	param
	(
		[string] $mycategory,
		[string] $mymessage
	)

    begin
    {
	    $mydate = get-date
	    $myFgColor = "Gray"
	    switch ($mycategory)
	    {
		    "INFO" {$myFgColor = "Green"}
		    "WARNING" {$myFgColor = "Yellow"}
		    "ERROR" {$myFgColor = "Red"}
		    "SUM" {$myFgColor = "Magenta"}
	    }
    }

    process
    {
	    Write-Host -ForegroundColor $myFgColor "$mydate [$mycategory] $mymessage"
	    if ($log) {Write-Output "$mydate [$mycategory] $mymessage" >>$myOutputLogFile}
    }
}

#this function is used to create a DRS host group
Function New-DrsHostGroup {
<#
.SYNOPSIS
  Creates a new DRS host group
.DESCRIPTION
  This function creates a new DRS host group in the DRS Group Manager
.NOTES
  Author: Arnim van Lieshout
.PARAMETER VMHost
  The hosts to add to the group. Supports objects from the pipeline.
.PARAMETER Cluster
  The cluster to create the new group on.
.PARAMETER Name
  The name for the new group.
.EXAMPLE
  PS> Get-VMHost ESX001,ESX002 | New-DrsHostGroup -Name "HostGroup01" -Cluster CL01
.EXAMPLE
  PS> New-DrsHostGroup -Host ESX001,ESX002 -Name "HostGroup01" -Cluster (Get-CLuster CL01)
#>
 
    Param(
        [parameter(valuefrompipeline = $true, mandatory = $true,
        HelpMessage = "Enter a host entity")]
            [PSObject]$VMHost,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a cluster entity")]
            [PSObject]$Cluster,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a name for the group")]
            [String]$Name)
 
    begin {
        switch ($Cluster.gettype().name) {
            "String" {$cluster = Get-Cluster $cluster | Get-View}
            "ClusterImpl" {$cluster = $cluster | Get-View}
            "Cluster" {}
            default {throw "No valid type for parameter -Cluster specified"}
        }
        $spec = New-Object VMware.Vim.ClusterConfigSpecEx
        $group = New-Object VMware.Vim.ClusterGroupSpec
        $group.operation = "add"
        $group.Info = New-Object VMware.Vim.ClusterHostGroup
        $group.Info.Name = $Name
    }
 
    Process {
        switch ($VMHost.gettype().name) {
            "String[]" {Get-VMHost -Name $VMHost | %{$group.Info.Host += $_.Extensiondata.MoRef}}
            "String" {Get-VMHost -Name $VMHost | %{$group.Info.Host += $_.Extensiondata.MoRef}}
            "VMHostImpl" {$group.Info.Host += $VMHost.Extensiondata.MoRef}
            "HostSystem" {$group.Info.Host += $VMHost.MoRef}
            default {throw "No valid type for parameter -VMHost specified"}
        }
    }
 
    End {
        if ($group.Info.Host) {
            $spec.GroupSpec += $group
            $cluster.ReconfigureComputeResource_Task($spec,$true) | Out-Null
        }
        else {
            throw "No valid hosts specified"
        }
    }
}

#this function is used to create a DRS VM group
Function New-DrsVmGroup {
<#
.SYNOPSIS
  Creates a new DRS VM group
.DESCRIPTION
  This function creates a new DRS VM group in the DRS Group Manager
.NOTES
  Author: Arnim van Lieshout
.PARAMETER VM
  The VMs to add to the group. Supports objects from the pipeline.
.PARAMETER Cluster
  The cluster to create the new group on.
.PARAMETER Name
  The name for the new group.
.EXAMPLE
  PS> Get-VM VM001,VM002 | New-DrsVmGroup -Name "VmGroup01" -Cluster CL01
.EXAMPLE
  PS> New-DrsVmGroup -VM VM001,VM002 -Name "VmGroup01" -Cluster (Get-CLuster CL01)
#>
 
    Param(
        [parameter(valuefrompipeline = $true, mandatory = $true,
        HelpMessage = "Enter a vm entity")]
            [PSObject]$VM,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a cluster entity")]
            [PSObject]$Cluster,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a name for the group")]
            [String]$Name)
 
    begin {
        switch ($Cluster.gettype().name) {
            "String" {$cluster = Get-Cluster $cluster | Get-View}
            "ClusterImpl" {$cluster = $cluster | Get-View}
            "Cluster" {}
            default {throw "No valid type for parameter -Cluster specified"}
        }
        $spec = New-Object VMware.Vim.ClusterConfigSpecEx
        $group = New-Object VMware.Vim.ClusterGroupSpec
        $group.operation = "add"
        $group.Info = New-Object VMware.Vim.ClusterVmGroup
        $group.Info.Name = $Name
    }
 
    Process {
        switch ($VM.gettype().name) {
            "String[]" {Get-VM -Name $VM | %{$group.Info.VM += $_.Extensiondata.MoRef}}
            "String" {Get-VM -Name $VM | %{$group.Info.VM += $_.Extensiondata.MoRef}}
            "VirtualMachineImpl" {$group.Info.VM += $VM.Extensiondata.MoRef}
            "VirtualMachine" {$group.Info.VM += $VM.MoRef}
            default {throw "No valid type for parameter -VM specified"}
        }
    }
 
    End {
        if ($group.Info.VM) {
            $spec.GroupSpec += $group
            $cluster.ReconfigureComputeResource_Task($spec,$true) | Out-Null
        }
        else {
            throw "No valid VMs specified"
        }
    }
}

#this function is used to create a VM to host DRS rule
Function New-DRSVMToHostRule{
<#
.SYNOPSIS
  Creates a new DRS VM to host rule
.DESCRIPTION
  This function creates a new DRS vm to host rule
.NOTES
  Author: Arnim van Lieshout
.PARAMETER VMGroup
  The VMGroup name to include in the rule.
.PARAMETER HostGroup
  The VMHostGroup name to include in the rule.
.PARAMETER Cluster
  The cluster to create the new rule on.
.PARAMETER Name
  The name for the new rule.
.PARAMETER AntiAffine
  Switch to make the rule an AntiAffine rule. Default rule type is Affine.
.PARAMETER Mandatory
  Switch to make the rule mandatory (Must run rule). Default rule is not mandatory (Should run rule)
.EXAMPLE
  PS> New-DrsVMToHostRule -VMGroup "VMGroup01" -HostGroup "HostGroup01" -Name "VMToHostRule01" -Cluster CL01 -AntiAffine -Mandatory
#>
 
    Param(
        [parameter(mandatory = $true,
        HelpMessage = "Enter a VM DRS group name")]
            [String]$VMGroup,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a host DRS group name")]
            [String]$HostGroup,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a cluster entity")]
            [PSObject]$Cluster,
        [parameter(mandatory = $true,
        HelpMessage = "Enter a name for the group")]
            [String]$Name,
            [Switch]$AntiAffine,
            [Switch]$Mandatory)
 
    switch ($Cluster.gettype().name) {
        "String" {$cluster = Get-Cluster $cluster | Get-View}
        "ClusterImpl" {$cluster = $cluster | Get-View}
        "Cluster" {}
        default {throw "No valid type for parameter -Cluster specified"}
    }
 
    $spec = New-Object VMware.Vim.ClusterConfigSpecEx
    $rule = New-Object VMware.Vim.ClusterRuleSpec
    $rule.operation = "add"
    $rule.info = New-Object VMware.Vim.ClusterVmHostRuleInfo
    $rule.info.enabled = $true
    $rule.info.name = $Name
    $rule.info.mandatory = $Mandatory
    $rule.info.vmGroupName = $VMGroup
    if ($AntiAffine) {
        $rule.info.antiAffineHostGroupName = $HostGroup
    }
    else {
        $rule.info.affineHostGroupName = $HostGroup
    }
    $spec.RulesSpec += $rule
    $cluster.ReconfigureComputeResource_Task($spec,$true) | Out-Null
}

#########################
##   main processing   ##
#########################

#check if we need to display help and/or history
$HelpText = @'
################################################################################
 Name    : add-DRSRule.ps1
 Date    : 18/06/2015
 Author  : sbourdeaud@nutanix.com
 Purpose : This script helps create DRS VM and host groups and VM to host DRS
           rules. It can use files as input and can also automatically and
           arbitrarily load balance VMs and hosts in two separate groups.
 
 Usage   :
           ./add-DRSRule [-vcenter] <hostname> [-cluster] <cluster name>
                         [-hostgroup] <name> [-hosts] <csv list>
                         [-vmgroup] <name> [-vms] <csv list>
                         [-vmtohost] <name,vmgroup,hostgroup> [-should] [-must]
                         [-lb] [-folder] <name> [-help][-history][-log]
 
            where
                  -vcenter   VMware vCenter server hostname. Default is
                             localhost. You can specify several hostnames by
                             separating entries with commas.
                  -cluster   Specify the cluster name. (Mandatory)
                  -hostgroup Name of the host group you want to create.
                  -hosts     List (comma separated, enclosed in double quotes)
                             of hosts to add to the host  group. This can be a
                             file with one entry per line.
                             (Mandatory if -hostgroup has been specified)
                  -vmgroup   Name of the vmgroup you want to create.
                  -vms       List (comma separated, enclosed in double quotes)
                             of vms to add to the vm group. This can be a 
                             file with one entry per line.
                             (Mandatory if -vmgroup has been specified)
                  -vmtohost  Name of the VM to Host rule you want to create.
                             If -hostgroup and -vmgroup have not both been
                             specified, you must follow the rule name by the
                             host group name and the vm group name (all
                             separated with a comma).
                             (Mandatory)
                  -should    Specifies that the VM to host rule is a "should"
                  -must      Specifies that the VM to host rule is a "must"
                  -lb        Automatically load balance the groups and rules.
                             When you use that option, simply give a flat list
                             of objects you want to distribute in the -hosts and
                             -vms parameters.  The script will distribute the
                             hosts and vms in separate groups (appending 1 and 2
                             to the specified -hostgroup and -vmgroup values) in
                             a round robin fashion using the list of objects in
                             alphabetical order.  It will then create two VMs to
                             hosts rules (appending 1 and 2 to the -vmtohost
                             parameter). If -hostgroup, -vmgroup and -vmtohost
                             have not been specified, it will default to
                             g_hosts[1-2], g_vms[1-2] for group names and
                             r_group[1-2] for rule names.  It will then process
                             all hosts and vms in the cluster (unless -folder
                             has been specified, in which case it will only
                             process VMs in that folder).
                  -help      Produces this help output.
                  -history   Produces help output with maintenance history.
                  -log       Specifies that you want the output messages to be
                             written in a log file as well as on the screen.
 
################################################################################
'@
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 06/18/2015 sb   Initial version.
################################################################################
'@
 
	if ($help -or $history)
	{
		$HelpText;
		if ($History){$HistoryText}
		exit
	}



#let's make sure the VIToolkit is being used
if ((Get-PSSnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null)#is it already there?
{
	Add-PSSnapin VMware.VimAutomation.Core #no? let's add it
	if (!$?) #have we been able to add it successfully?
	{
		OutputLogData -category "ERROR" -message "Unable to load the PowerCLI snapin.  Please make sure PowerCLI is installed on this server."
		return
	}
} 
#Initialize-VIToolkitEnvironment.ps1 | Out-Null

#initialize variables
	#misc variables
	$myElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
	$myvCenterServers = @() #used to store the list of all the vCenter servers we must connect to
	$myOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
	$myOutputLogFile += "OutputLog.log"

    $myHostGroup1,$myHostGroup2,$myVMGroup1,$myVMGroup2=@()
	
	############################################################################
	# command line arguments initialization
	############################################################################	
	#let's initialize parameters if they haven't been specified
	if (!$vcenter) {$myvCenterServers += $env:computername}#assign localhost if no vCenter has been specified
	else{$myvCenterServers = $vcenter.Split()}#otherwise make sure we parse the argument in case it contains several entries
	if (!$cluster) {OutputLogData -mycategory "ERROR" -mymessage "You must specify a cluster name!"; break}
	if ($hostgroup -and !$hosts -and !$lb) {OutputLogData -mycategory "ERROR" -mymessage "You must specify a list of hosts using -hosts with -hostgroup!"; break}
	if ($vmgroup -and !($vms -or $folder)) {OutputLogData -mycategory "ERROR" -mymessage "You must specify a list of vms using -vms or -folder with -vmgroup!"; break}
	if (!$vmtohost -and !$lb) {OutputLogData -mycategory "ERROR" -mymessage "You must specify the -vmtohost parameter!"; break}
	if ((($vmtohost.Split()).count -le 2) -and (!$hostgroup -or !$vmgroup) -and !$lb) {OutputLogData -mycategory "ERROR" -mymessage "You have not specified -hostgroup and -vmgroup. You must add the vmgroup and hostgroup names to the -vmtohost parameter separating them with commas!"; break}
	if (!$should -and !$must) {OutputLogData -mycategory "ERROR" -mymessage "You must specify -should or -must!"; break}
    if ($lb -and !$folder -and !$vms) {OutputLogData -mycategory "ERROR" -mymessage "You must specify -folder or -vms with -lb!"; break}
    if (Test-Path $vms) {$vms = (get-content $vms) -join " "} #a file was specified for -vms, let's read its content
    if (Test-Path $hosts) {$hosts = (get-content $hosts) -join " "} #a file was specified for -hosts, let's read its content
	
	################################
	##  foreach vCenter loop      ##
	################################
	foreach ($myvCenter in $myvCenterServers)	
	{
		OutputLogData -mycategory "INFO" -mymessage "Connecting to vCenter server $myvCenter..."
		if (!($myvCenterObject = Connect-VIServer $myvCenter))#make sure we connect to the vcenter server OK...
		{#make sure we can connect to the vCenter server
			$myerror = $error[0].Exception.Message
			OutputLogData -mycategory "ERROR" -mymessage "$myerror"
			return
		}
		else #...otherwise show the error message
		{
			OutputLogData -mycategory "INFO" -mymessage "Connected to vCenter server $myvCenter."
		}#endelse
		
		if ($myvCenterObject)
		{
		
			######################
			#main processing here#
			######################
			
			#intialize some variables containing objects that need processing
            ####################################
            # LOAD BALANCING
            ####################################
			if ($lb) #load balancing has been specified
			{
                ##################
                # POPULATE OBJECTS
                ##################
                OutputLogData -mycategory "INFO" -mymessage "Using load balancing..."
				if (!$vms) #no VMs have been specified...
				{
					OutputLogData -mycategory "INFO" -mymessage "Getting list of VMs from the folder $folder..."
					$myVMs = Get-Folder $folder | Get-VM | Sort-Object -Property Name #a folder has been specified, therefore we will process VMs in that folder for load balancing
				} #we specified a list of vms
                else
				{
                    OutputLogData -mycategory "INFO" -mymessage "Retrieving VM objects..."
					$myVMs = $vms.Split() | foreach {Get-VM -Name $_} | Sort-Object -Property Name #a folder has not been specified, therefore we will use the provided list of VMs
				}
				if (!$hosts) #no hosts have been specified...
				{
                    OutputLogData -mycategory "INFO" -mymessage "Getting the list of hosts from the cluster $cluster..."
					$myHosts = Get-Cluster $cluster | Get-VMHost | Sort-Object -Property Name
				} #we specified a list of hosts
                else
                {
                    OutputLogData -mycategory "INFO" -mymessage "Getting the list of hosts from the cluster $cluster..."
					$myHosts = $hosts.Split() | foreach {Get-VMHost -Name $_} | Sort-Object -Property Name
                }
                ###################
                # BALANCE
                ###################
                #now that we have our list of vms and hosts, we need to split them in two groups
                $myHostGroup1 = @(); $myHostGroup2 = @(); $myVMGroup1 = @(); $myVMGroup2 = @()
                $myCounter=0
                #balance hosts
                while ($myCounter -lt $myHosts.Count)
                {
                    if ($myCounter % 2)
                    {
                        $myHostGroup2 += $myHosts[$myCounter]
                    }
                    else
                    {
                        $myHostGroup1 +=  $myHosts[$myCounter]
                    }
                    ++$myCounter #let's increase our loop counter
                }
                #balance vms
                $myCounter=0
                while ($myCounter -lt $myVMs.Count)
                {
                    if ($myCounter % 2)
                    {
                        $myVMGroup2 += $myVMs[$myCounter]
                    }
                    else
                    {
                        $myVMGroup1 +=  $myVMs[$myCounter]
                    }
                    ++$myCounter #let's increase our loop counter
                }
                #########################
                # CREATE GROUPS & RULES
                #########################
                #create the DRS host groups
                if ($hostgroup) {$myhostgroupname1=$hostgroup + "1"; $myhostgroupname2=$hostgroup + "2"} else {$myhostgroupname1="g_hosts1"; $myhostgroupname2="g_hosts2"}
                if ($vmgroup) {$myvmgroupname1=$vmgroup + "1"; $myvmgroupname2=$vmgroup + "2"} else {$myvmgroupname1="g_vms1"; $myvmgroupname2="g_vms2"}
                if ($vmtohost) {$myrulename1=$vmtohost + "1"; $myrulename2=$vmtohost + "2"} else {$myrulename1="r_group1"; $myrulename2="r_group2"}
                OutputLogData -mycategory "INFO" -mymessage "Creating the first DRS host group..."
                $myHostGroup1 | New-DrsHostGroup -Name $myhostgroupname1 -Cluster $cluster
                OutputLogData -mycategory "INFO" -mymessage "Creating the second DRS host group..."
                $myHostGroup2 | New-DrsHostGroup -Name $myhostgroupname2 -Cluster $cluster
                #create the DRS vm groups
                OutputLogData -mycategory "INFO" -mymessage "Creating the first DRS vm group..."
                $myVMGroup1 | New-DrsVMGroup -Name $myvmgroupname1 -Cluster $cluster
                OutputLogData -mycategory "INFO" -mymessage "Creating the second DRS vm group..."
                $myVMGroup2 | New-DrsVMGroup -Name $myvmgroupname2 -Cluster $cluster
                #create the DRS VM to host rules
                if ($must) 
                {
                    OutputLogData -mycategory "INFO" -mymessage "Creating the first DRS VM to host group must rule..."
                    New-DrsVMToHostRule -VMGroup $myvmgroupname1 -HostGroup $myhostgroupname1 -Name $myrulename1 -Cluster $cluster -Mandatory
                    OutputLogData -mycategory "INFO" -mymessage "Creating the second DRS VM to host group must rule..."
                    New-DrsVMToHostRule -VMGroup $myvmgroupname2 -HostGroup $myhostgroupname2 -Name $myrulename2 -Cluster $cluster -Mandatory
                }
				if ($should) 
                {
                    OutputLogData -mycategory "INFO" -mymessage "Creating the first DRS VM to host group should rule..."
                    New-DrsVMToHostRule -VMGroup $myvmgroupname1 -HostGroup $myhostgroupname1 -Name $myrulename1 -Cluster $cluster
                    OutputLogData -mycategory "INFO" -mymessage "Creating the second DRS VM to host group should rule..."
                    New-DrsVMToHostRule -VMGroup $myvmgroupname2 -HostGroup $myhostgroupname2 -Name $myrulename2 -Cluster $cluster
                }
			}
            #####################################################
            # NO LOAD BALANCING - CREATE GROUPS
            #####################################################
			elseif ($hostgroup -and $vmgroup) #we're not load balancing and we need to create a host group and vmgroup
			{
				if ($folder) #a folder name has been specified...
				{
                    OutputLogData -mycategory "INFO" -mymessage "Getting list of VMs from the folder $folder..."
					$myVMs = Get-Folder $folder | Get-VM #...therefore we must process all VMs in that folder
					#let's create our vm group
                    OutputLogData -mycategory "INFO" -mymessage "Creating DRS VM group $vmgroup..."
					$myVMs | New-DrsVmGroup -Name $vmgroup -Cluster (Get-CLuster $cluster)
				}
				else #a folder name has not been specified...
				{
					#let's create our vm group
                    OutputLogData -mycategory "INFO" -mymessage "Creating DRS VM group $vmgroup..."
					New-DrsVmGroup -Name $vmgroup -Cluster $cluster -VM ($vms.Split())
				}#endif $folder
				
				#let's create our host group
                OutputLogData -mycategory "INFO" -mymessage "Creating DRS host group $hostgroup..."
                New-DrsHostGroup -Name $hostgroup -Cluster $cluster -VMHost ($hosts.Split())
				
				#let's create our vm to host rule
				if ($must) 
                {
                    OutputLogData -mycategory "INFO" -mymessage "Creating DRS VM to host group must rule $vmtohost..."
                    New-DrsVMToHostRule -VMGroup $vmgroup -HostGroup $hostgroup -Name $vmtohost -Cluster $cluster -Mandatory
                }
				if ($should) 
                {
                    OutputLogData -mycategory "INFO" -mymessage "Creating DRS VM to host group should rule $vmtohost..."
                    New-DrsVMToHostRule -VMGroup $vmgroup -HostGroup $hostgroup -Name $vmtohost -Cluster $cluster
                }
			}
            #####################################################
            # NO LOAD BALANCING - DON'T CREATE GROUPS
            #####################################################
			else #we're not load balancing, and we don't need to create a host and vm group
			{
                #let's intialize some variables

				#let's create our vm to host rule
				if ($must) 
                {
                    OutputLogData -mycategory "INFO" -mymessage "Creating DRS VM to host group must rule $vmtohost..."
                    New-DrsVMToHostRule -VMGroup ($vmtohost.split())[1] -HostGroup ($vmtohost.split())[2] -Name ($vmtohost.split())[0] -Cluster $cluster -Mandatory
                }
				if ($should) 
                {
                    OutputLogData -mycategory "INFO" -mymessage "Creating DRS VM to host group should rule $vmtohost..."
                    New-DrsVMToHostRule -VMGroup ($vmtohost.split())[1] -HostGroup ($vmtohost.split())[2] -Name ($vmtohost.split())[0] -Cluster $cluster
                }
			} #end if
						
		}#endif $myvCenterObject
        OutputLogData -mycategory "INFO" -mymessage "Disconnecting from vCenter server $vcenter..."
		Disconnect-viserver -Confirm:$False #cleanup after ourselves and disconnect from vcenter
	}#end foreach vCenter
	
############################
#        CLEANUP
############################


	#let's figure out how much time this all took
	OutputLogData -mycategory "SUM" -mymessage "total processing time: $($myElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable my*
	Remove-Variable ErrorActionPreference
	Remove-variable help
	Remove-variable log
	Remove-variable vcenter
	Remove-Variable cluster
	Remove-Variable hostgroup
	Remove-Variable vmgroup
	Remove-Variable vmtohost
	Remove-Variable should
	Remove-Variable must
	Remove-Variable lb
	Remove-Variable hosts
	Remove-Variable vms
	Remove-Variable folder
    Remove-Variable debugme