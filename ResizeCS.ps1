##
#
#
# ResizeCS - Script to delete and resize all VMs in a cloud service to an new size.
#                   
#    Note: This script will resize all VMs in the cloud service to the specified conversion. After
#          executing this script individual VMs can be resized via a reboot to alternate sizes
#          that are supported by the specific hardware cluster where the cloud service was 
#          redeployed.
#
#    Example:  .\ResizeCS.ps1 -CloudService ResizeTestVM -NewSizes ("Standard_DS1","Standard_DS1_v2"),("Standard_DS2","standard_ds2_v2") -OutputFile logfile.txt  -CommandOutputFile resizeCommands.ps1 
###

[CmdletBinding()]
Param(
  [string]$CloudService = $(Read-Host -prompt "Specify the the Cloud Service that contains VMs to be resized"),
  [string[][]]$NewSizes = $(Read-Host -prompt "Specify the size changes to make to VMs in the cloud service"),
  [string]$OutputFile = $(Read-Host -prompt "Specify a file to store the log output of the operations"),
  [string]$CommandOutputFile= $(Read-Host -prompt "Specify a file to store the generated PowerShell scripts"),
  [switch]$AllowServiceVipChange,
  [switch]$AllowVMPublicIPChange,
  [switch]$AllowVNetIPChange,
  [switch]$AllowRemovalOfAffinityGroup
  )


$ErrorActionPreference = "Stop"
$testMode = $true
if($testMode)
{
    Write-Host "Script is in test mode, no changes will be made." -ForegroundColor Green
}

Write-Host "Validating change request..." -ForegroundColor Green
#
#region Verify VM Size
#
$validSizes = Get-AzureRoleSize
foreach($SizePair in $NewSizes)
{
    $CurrentSize = $SizePair[0]
    $NewSize = $SizePair[1]
    
    $isNewSizeValid = $false
    foreach ($validSize in $validSizes ){
        if ($validSize.InstanceSize.ToLower() -eq $NewSize) {
            $isNewSizeValid = $true
            $SizePair[1] = $validSize.InstanceSize # avoid any case issues
            #$newsizeDiskCount = $validSize.MaxDataDiskCount
        }
    }

    if (-Not($isNewSizeValid)) {
        write-host
        write-host "ERROR: The size" $NewSize "is not a valid VM size"
        write-host
        return 
    }
}
#endregion

#
#region Check to see if reboot can be used to resize
#
#
# Verify that specified VM size is not already supported via a reboot
#
#    Note: This requires a bit of a work-around due to the fact that VM sizes available
#          in an existing deployment are only returned when querying all cloud servcies,
#          and not returned when a specficific cloud service is queried
#

$allCloudServices = Get-AzureService
foreach($SizePair in $NewSizes)
{
    $CurrentSize = $SizePair[0]
    $NewSize = $SizePair[1]

    $foundCloudService = $false
    $canRebootToResize = $false

    if ($allCloudServices.Count -eq "0"){
        write-host
        write-host "ERROR: No cloud services were found in the default subscription."
        write-host
        return
    }

    foreach ($service in $allCloudServices){
        if ($service.ServiceName.ToLower() -eq $CloudService.ToLower()){
            $foundCloudService = $true
        
            foreach ($vmsize in $service.VirtualMachineRoleSizes) {
                if($vmsize.ToLower() -eq $NewSize.ToLower()){
                    $canRebootToResize = $true
                }
            }
        }    
    }

    if (-Not ($foundCloudService)) {
        write-host
        write-host "ERROR: Cloud Service" $CloudService "was not found."
        write-host
        return
    }

    if ($canRebootToResize){
        write-host
        write-host "ERROR: VMs in the cloud service" $CloudService "of size " $CurrentSize "can be resized to" $NewSize "through standard resize operations."
        write-host
        return
    }    
}
#endregion


#
# Get CS and Deployment details
#
write-host
Write-Host "INFO:    Reading Cloud Service Details"
$service = Get-AzureService -ServiceName $CloudService
"Service Details:" | Out-File $OutputFile
$service | Out-File -Append $OutputFile

$deployment = Get-AzureDeployment -ServiceName $CloudService
"Deployment Details" | Out-File -Append $OutputFile
$deployment | Out-File -Append $OutputFile

$VNet = Get-AzureDeployment -ServiceName $CloudService | Select Vnetname 
$VNet | Out-File -Append $OutputFile

#region Ensure the existing CloudService is not in an AffinityGroup
#

$isAffinityGroup = $false
if ($service.AffinityGroup -ne $null){
    $isAffinityGroup = $true
    $AffinityGroup = Get-AzureAffinityGroup -Name $service.AffinityGroup
    $location = $AffinityGroup.Location


    if ($AllowRemovalOfAffinityGroup) {
        write-host
        write-host "WARNING: Continuing with cloud service in an Affinity Group. This will result in the CloudService being recreated without an Affinity Group." | Out-File $OutputFile
    } else {
        write-host
        write-host "ERROR: The selected cloud service is deployed to an affinity group. Please specify '-AllowRemovalOfAffinityGroup' to resize and allow the VMs to be removed from the Affinity Group."
        write-host
        return
    }

} else {
    $location = $service.Location
}
#endregion


#region Verify new size is available in the existing region
#
$locationDetails = Get-AzureLocation | where {$_.DisplayName.ToString() -eq $location}

$validSizesForRegion = $locationDetails.VirtualMachineRoleSizes
foreach($SizePair in $NewSizes)
{
    $CurrentSize = $SizePair[0]
    $NewSize = $SizePair[1]

    $isNewSizeValid = $false
    foreach ($validSize in $validSizesForRegion ){
        if ($validSize -eq $NewSize) {
            $isNewSizeValid = $true
        }
    }

    if (-Not($isNewSizeValid)) {
        write-host
        write-host "ERROR: The size" $NewSize "is not a valid VM size in the current region:" $location
        write-host
        return 
    }
}
#endregion

#region check for reserved VIP
#

#
# Verify VIP is reserved or allow IP changes is set
#
write-host "INFO:    Checking for reserved IP address on VIP"

$reservedIPName = $deployment.VirtualIPs[0].ReservedIPName

if ($reservedIPName) {
    "Reserved VIP Details:" | Out-File -Append $OutputFile
    Get-AzureReservedIP -ReservedIPName $reservedIPName | Out-File -Append $OutputFile
} else {
    if ($AllowServiceVipChange) {
        write-host
        write-host "WARNING: Continuing with unreserved VIP. IP address of VIP will change after resize."
        "WARNING: Continuing with unreserved VIP. IP address of VIP will change after resize." | Out-File $OutputFile
    } else {
        write-host
        write-host "ERROR: The selected cloud service does not have a reserved VIP. Please specify '-AllowServiceVipChange' to resize and allow the IP address to change."
        write-host
        return
    }

}

#endregion

#region check for custom DNS and reverse FQDN

#
# TODO: Add support for Cloud Service with custom DNS configuration
#
if ($deployment.DnsSettings) {
    write-host
    write-host "ERROR: This script does not support cloud services with custom DNS configuration"
    write-host
    return
}


#
# TODO: Add support for Cloud Service with Reverse DNS Configuration
#
if ($service.ReverseDnsFqdn) {
    write-host
    write-host "ERROR: This script does not support cloud services with Reverse FQDN configured"
    write-host
    return
}

#endregion


#
# Get the ILB if one is in use
#
$internalLB = Get-AzureInternalLoadBalancer -ServiceName $CloudService
if ($internalLB) {
    Write-host "INFO:    Getting ILB Configuration"
    "Internal LB:" | Out-File -Append $OutputFile
    $internalLB | Out-File -Append $OutputFile 
}



#
# Gather the details for each VM
#

write-host "INFO:    Reading VM details"
$vms = Get-AzureVM -ServiceName $CloudService

$ipForwardingStatuses = @()

foreach ($vm in $vms){

    $foundCurrentSize = $false
    foreach($SizePair in $NewSizes)
    {
        if($SizePair[0].ToLower() -eq $vm.InstanceSize.ToLower())
        {
            $CurrentSize = $vm.InstanceSize;
            $NewSize = $SizePair[1]
            $foundCurrentSize = $true;
        }
    }
    if (-Not ($foundCurrentSize)) {
        Write-Host
        Write-Host "No VM found at current size of $CurrentSize. Unable to continue with resizing" -ForegroundColor Red
        Write-Host
        return
    }
    
    write-host "INFO:    Getting Details for VM:" $vm.name
    $vm | Out-File -Append $OutputFile

    $SubNet = Get-AzureSubnet -VM $vm 
    "Subnet:" | Out-File -Append $OutputFile
    $SubNet | Out-File -Append $OutputFile

    $Endpoints = Get-AzureEndpoint -VM $vm 
    "Endpoints:" | Out-File -Append $OutputFile
    $Endpoints | Out-File -Append $OutputFile

    $OSDisk = $vm.vm.OSVirtualHardDisk 
    "OS Disk:" | Out-File -Append $OutputFile
    $OSDisk | Out-File -Append $OutputFile

    $DataDisks = $vm.vm.DataVirtualHardDisks 
    "Data Disks:" | Out-File -Append $OutputFile
    $DataDisks | Out-File -Append $OutputFile


    $vmExtensions = Get-AzureVMExtension -VM $vm
    "VM Extensions:" | Out-File -Append $OutputFile
    $vmExtensions | Out-File -Append $OutputFile

    #
    # Verify the new size will support the number of data disks
    #
     foreach ($validSize in $validSizes ){
        if ($validSize.InstanceSize.ToLower() -eq $NewSize) {
            $newsizeDiskCount = $validSize.MaxDataDiskCount
        }
    }

    if ($DataDisks.count -gt $newsizeDiskCount) {
        write-host
        write-host "ERROR: The VM:" $vm.name "has more data disks ($($DataDisks.count)) than are supported on the selected VM size ($newsizeDiskCount)."
        write-host
        return
    }

#region Check for Premium Storage Compatability
    #
    # Verify that we are not trying to use a non-premium VM with premium storage
    #
    $usingPremiumStorage = $false
    if ($OSDisk.IOType -eq "Provisioned") {
        $usingPremiumStorage = $true    
    }
    foreach ($disk in $DataDisks) {
        if ($disk.IOType -eq "Provisioned") {
            $usingPremiumStorage = $true    
        }
    }

    if ($usingPremiumStorage) {
        if (($NewSize -like "Standard_DS*") -or ($NewSize -like "Standard_GS*")){
            # Size is good
        } else {
            write-host 
            write-host "Error: One of the original VMs is using premium storage, and the selected size is not a DS or GS size."
            write-host
            return
        }
    }

#endregion

#
#region Warn on any IP address changes
#
    # Check for Public IP addresses and warn that they will change
    #    
    if ($vm.PublicIpAddress ) {
        if ($AllowVMPublicIPChange){
            write-host "WARNING: Public IP address for VM:" $vm.Name "will change after resize."
        } else {
            write-host
            write-host "ERROR: The VM:" $vm.Name "has a public IP address which will change. Please specify '-AllowVMPublicIPChange' to resize and allow the IP address to change."
            write-host
            return
        }
    }

    # Check for static VNet IP addresses and warn that VNet address will change if not static
    $StaticIP = Get-AzureStaticVNetIP -VM $vm.vm
    
    if ($StaticIP) {
        "Static IP address:" | Out-File -Append $OutputFile
        $StaticIP | Out-File -Append $OutputFile
    } else {
        if ($AllowVNetIPChange) {
            write-host "WARNING: VNet IP address for VM:" $vm.Name "may change after resize."
        } else {
            write-host
            write-host "ERROR: The VM:" $vm.name "is not configured for a static VNet IP address. Please specify '-AllowVNetIPChange' to resize allowing the VNet IP address of the VM to change."
            write-host
            return
        }
    }

#endregion

    # Get the status for IP Forwarding
    $ipForwardingStatus = Get-AzureIPForwarding -VM $vm -ServiceName $CloudService
    "IP Forwarding Status:" | Out-File -Append $OutputFile
    $ipForwardingStatus| Out-File -Append $OutputFile

    $ipForwardingStatuses += $ipForwardingStatus

#
#region Block running if any VM is in a provisioning state
#
    if ($vm.InstanceStatus -like "*Provisioning*"){
            write-host
            write-host "ERROR: The VM:" $vm.Name "is currently in a Provisioning state. Please wait for provisioning to complete before attempting to resize the VM."
            write-host
            return
    }    
#endregion 


#
#region Warn if any VM is in a stopped or stopped-deallocated state
#
    if ($vm.InstanceStatus -like "*Stop*"){
        write-host "WARNING: The following VM is currently stopped and will be restarted at the end of this script:" $vm.Name 
    }    
#endregion 

#
#region Block if using multiple NICs or NSGs
#
    #
    # TODO: Extend script to support VMs with multiple NICs
    #       
    # 
    $multiNic = Get-AzureNetworkInterfaceConfig -VM $vm
    if ($multiNic) {
        write-host
        write-host "ERROR: This script does not support changing the size of VMs that have multiple NICs."
        write-host
        return
    } 

    #
    # TODO: Extend script to support VMs with network security groups
    #       
    #
    $nsg = Get-AzureNetworkSecurityGroupAssociation -VM $vm -ServiceName $vm.ServiceName -ErrorAction SilentlyContinue 
    if ($nsg) {
        write-host
        write-host "ERROR: This script does not support changing the size of VMs use network security groups."
        write-host
        return
    } 

#endregion

}


#
# Pause to get user confirmation before deleting cloud service
#
write-host
write-host "Please review details. Click Enter to continue or CTRL+C to exit script"
if($testMode)
{
    Write-Host "Script is in test mode, no changes will be made. PowerShell scripts will be saved to file: $CommandOutputFile" -ForegroundColor Green
}
else
{
    Write-Host "Script is NOT test mode, no changes WILL be made" -ForegroundColor Yellow
}
write-host

pause
write-host

#
# Array to collect command execution
#

$commands = @()


#
# Delete deployment saving all disks
#
$commands += "# Get a reference to the existing VMs"
$commands += "`$vms = Get-AzureVM -ServiceName $($CloudService)"
if ($reservedIPName)
{
    $commands += "#Set reserved IP name"
    $commands += "`$reservedIPName = $reservedIPName"
}
$commands += "# Remove the VMs from the Cloud Service"
$commands += "Remove-AzureDeployment -ServiceName $($CloudService) -Slot Production -Force -Verbose"
$commands += ""
$commands += "
# Wait for disks to detach
#
foreach (`$vm in `$vms) {
        
    # Check OS Disk
    `$OSDisk = `$vm.vm.OSVirtualHardDisk 
    `$disk = Get-AzureDisk -DiskName `$OSDisk.DiskName
    Write-Host `"Detaching OS disk `$(`$disk.DiskName) from VM `$(`$vm.Name)`" 
    while (`$disk.AttachedTo -ne `$null) {
        Write-Host `"Waiting for disks to detach. VM:`" `$vm.Name `"Disk:`" `$disk.DiskName
        Sleep -Seconds 20
        `$disk = Get-AzureDisk -DiskName `$OSDisk.DiskName
    }
        
    # Check Data Disks
    foreach (`$datadisk in `$vm.vm.DataVirtualHardDisks) {
        `$disk = Get-AzureDisk -DiskName `$datadisk.DiskName
        Write-Host `"Detaching Data disk `$(`$disk.DiskName) from VM `$(`$vm.Name)`" 
        while (`$disk.AttachedTo -ne `$null) {
            `Write-Host `"Waiting for disks to detach. VM:`" `$vm.Name `"Disk:`" `$disk
            Sleep -Seconds 20
            `$disk = Get-AzureDisk -DiskName `$datadisk.DiskName
        }
    }
}"
try {
if($testMode -eq $false)
{
    Write-Host "Deleting the deployment"
    
    Remove-AzureDeployment -ServiceName $CloudService -Slot Production -Force



    #region Wait for disks to detach    
        #
        # Wait for disks to detach
        #
        foreach ($vm in $vms) {
        
            # Check OS Disk
            $OSDisk = $vm.vm.OSVirtualHardDisk 
            $disk = Get-AzureDisk -DiskName $OSDisk.DiskName
            while ($disk.AttachedTo -ne $null) {
                Write-Host "Waiting for disks to detach. VM:" $vm.Name "Disk:" $disk.DiskName
                Sleep -Seconds 20
                $disk = Get-AzureDisk -DiskName $OSDisk.DiskName
            }
        
            # Check Data Disks
            foreach ($datadisk in $vm.vm.DataVirtualHardDisks) {
                $disk = Get-AzureDisk -DiskName $datadisk.DiskName
                while ($disk.AttachedTo -ne $null) {
                    Write-Host "Waiting for disks to detach. VM:" $vm.Name "Disk:" $disk
                    Sleep -Seconds 20
                    $disk = Get-AzureDisk -DiskName $datadisk.DiskName
                }
            }
        }
}
#endregion 

    #
    # Ensure CurrentStorageAccount is set for the subscription
    #
    $commands += "# Ensure CurrentStorageAccount is set for the subscription
`$currentSub = Get-AzureSubscription -Current
if (-Not (`$currentSub.CurrentStorageAccountName)) {
    `$parser = `$OSDisk.MediaLink.Host.Split(".")
    `$StorageAccount = `$parser[0]
    Set-AzureSubscription -SubscriptionName `$currentSub.SubscriptionName -CurrentStorageAccountName `$StorageAccount
}"
    $currentSub = Get-AzureSubscription -Current
    if (-Not ($currentSub.CurrentStorageAccountName)) {
        $parser = $OSDisk.MediaLink.Host.Split(".")
        $StorageAccount = $parser[0]
        Set-AzureSubscription -SubscriptionName $currentSub.SubscriptionName -CurrentStorageAccountName $StorageAccount
    }

    #
    # Delete and Recreate the Cloud Service if it was in an affinity group
    #
    $commands += "# Delete and Recreate the Cloud Service if it was in an affinity group
if (`$isAffinityGroup){
    Remove-AzureService -ServiceName `$service.ServiceName -Force
    New-AzureService -ServiceName `$service.ServiceName -Location `$location
}"
    if ($isAffinityGroup){
        Remove-AzureService -ServiceName $service.ServiceName -Force
        New-AzureService -ServiceName $service.ServiceName -Location $location
    }

    
    #
    #  Deploy each VM
    #
    for ($i=0; $i -lt $vms.count; $i++) {
        $vm = $vms[$i]
        write-host "Building VM Config:" $vm.Name

        $foundCurrentSize = $false
        foreach($SizePair in $NewSizes)
        {
            if($SizePair[0].ToLower() -eq $vm.InstanceSize.ToLower())
            {
                $CurrentSize = $vm.InstanceSize;
                $NewSize = $SizePair[1]
                $foundCurrentSize = $true;
            }
        }


        $commands += "#Resize VM $($vm.Name) from $($vm.InstanceSize) to $NewSize"
        $commands += "`$NewVM = New-AzureVMConfig -Name $($vm.Name) -InstanceSize $($NewSize) -DiskName $($vm.vm.OSVirtualHardDisk.DiskName) -HostCaching $($vm.vm.OSVirtualHardDisk.HostCaching) " 
        $NewVM = New-AzureVMConfig -Name $vm.Name -InstanceSize $NewSize -DiskName $vm.vm.OSVirtualHardDisk.DiskName -HostCaching $vm.vm.OSVirtualHardDisk.HostCaching 
                               

        if ($vm.AvailabilitySetName) {
            $commands += "Set-AzureAvailabilitySet -AvailabilitySetName $($vm.AvailabilitySetName) -VM `$NewVM" 
            Set-AzureAvailabilitySet -AvailabilitySetName $vm.AvailabilitySetName -VM $NewVM 
        }

        foreach ($disk in $vm.vm.DataVirtualHardDisks) {
            $commands += "Add-AzureDataDisk -import -DiskName $($disk.DiskName) -LUN $($disk.LUN) -HostCaching $($disk.HostCaching) -VM `$NewVM" 
            Add-AzureDataDisk -import -DiskName $disk.DiskName -LUN $disk.LUN -HostCaching $disk.HostCaching -VM $NewVM
        }

        $Endpoints = Get-AzureEndpoint -VM $vm 
        foreach ($endpoint in $Endpoints) {
            if ($endpoint.LBSetName -ne $null ){
                if ($endpoint.InternalLoadBalancerName -ne $null)
                {
                    $commands += "Add-AzureEndpoint -LBSetName '$($endpoint.LBSetName)' -Name '$($endpoint.Name)' -Protocol $($endpoint.Protocol) -LocalPort $($endpoint.LocalPort) -PublicPort $($endpoint.Port) -ProbePort $($endpoint.ProbePort) -ProbeProtocol $($endpoint.ProbeProtocol) -ProbeIntervalInSeconds $($endpoint.ProbeIntervalInSeconds) -ProbeTimeoutInSeconds $($endpoint.ProbeTimeoutInSeconds) -DirectServerReturn $($endpoint.EnableDirectServerReturn) -InternalLoadBalancerName $($endpoint.InternalLoadBalancerName) -VM `$NewVM"
                    Add-AzureEndpoint -LBSetName $endpoint.LBSetName -Name $endpoint.Name -Protocol $endpoint.Protocol -LocalPort $endpoint.LocalPort -PublicPort $endpoint.Port -ProbePort $endpoint.ProbePort -ProbeProtocol $endpoint.ProbeProtocol -ProbeIntervalInSeconds $endpoint.ProbeIntervalInSeconds -ProbeTimeoutInSeconds $endpoint.ProbeTimeoutInSeconds -DirectServerReturn $endpoint.EnableDirectServerReturn -InternalLoadBalancerName $endpoint.InternalLoadBalancerName -VM $NewVM
                } else {
                    $commands += "Add-AzureEndpoint -LBSetName '$($endpoint.LBSetName)' -Name '$($endpoint.Name)' -Protocol $($endpoint.Protocol) -LocalPort $($endpoint.LocalPort) -PublicPort $($endpoint.Port) -ProbePort $($endpoint.ProbePort) -ProbeProtocol $($endpoint.ProbeProtocol) -ProbeIntervalInSeconds $($endpoint.ProbeIntervalInSeconds) -ProbeTimeoutInSeconds $($endpoint.ProbeTimeoutInSeconds) -DirectServerReturn $($endpoint.EnableDirectServerReturn) -VM `$NewVM" 
                    Add-AzureEndpoint -LBSetName $endpoint.LBSetName -Name $endpoint.Name -Protocol $endpoint.Protocol -LocalPort $endpoint.LocalPort -PublicPort $endpoint.Port -ProbePort $endpoint.ProbePort -ProbeProtocol $endpoint.ProbeProtocol -ProbeIntervalInSeconds $endpoint.ProbeIntervalInSeconds -ProbeTimeoutInSeconds $endpoint.ProbeTimeoutInSeconds -DirectServerReturn $endpoint.EnableDirectServerReturn -VM $NewVM
                }
            } else {
                $commands += "Add-AzureEndpoint -Name '$($endpoint.Name)' -Protocol $($endpoint.Protocol) -LocalPort $($endpoint.LocalPort) -PublicPort $($endpoint.Port) -VM `$NewVM"
                Add-AzureEndpoint -Name $endpoint.Name -Protocol $endpoint.Protocol -LocalPort $endpoint.LocalPort -PublicPort $endpoint.Port -VM $NewVM
            }
        }

        $SubNet = Get-AzureSubnet -VM $vm
        if ($SubNet -ne $null){
            $commands +="Set-AzureSubnet -SubnetNames $SubNet -VM `$NewVM"
            Set-AzureSubnet -SubnetNames $SubNet -VM $NewVM
        }

        $StaticIP = Get-AzureStaticVNetIP -VM $vm.vm
        if ($StaticIP -ne $null){
            $commands += "Set-AzureStaticVNetIP -IPAddress $($StaticIP.IPAddress) -VM `$NewVM" 
            Set-AzureStaticVNetIP -IPAddress $StaticIP.IPAddress -VM $NewVM
        }

        $vmExtensions = Get-AzureVMExtension -VM $vm
        foreach ($extension in $vmExtensions) {
            if (($extension.Version -ne $null) -and ($extension.Version -ne "")){
                if (($extension.ReferenceName -ne $null) -and ($extension.ReferenceName -ne "")) {
                    if (($extension.PublicConfiguration -ne $null) -and ($extension.PublicConfiguration -ne "")) {
                        #All non-NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -Version $($extension.Version) -ReferenceName $($extension.ReferenceName) -PublicConfiguration '$($extension.PublicConfiguration)'"
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -Version $extension.Version -ReferenceName $extension.ReferenceName -PublicConfiguration $extension.PublicConfiguration
                    } else {
                        #Only Public Config NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -Version $($extension.Version) -ReferenceName $($extension.ReferenceName)" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -Version $extension.Version -ReferenceName $extension.ReferenceName 
                    }
                } else {
                    if ($extension.PublicConfiguration -ne $null){
                        #Only ReferenceName NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -Version $($extension.Version) -PublicConfiguration '$($extension.PublicConfiguration)'" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -Version $extension.Version -PublicConfiguration $extension.PublicConfiguration
                    } else {
                        #Reference Name and Public Configuration NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -Version $($extension.Version)" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -Version $extension.Version  
                    }
                } 
            
            }else {
                if ($extension.ReferenceName -ne $null) {
                    if ($extension.PublicConfiguration -ne $null){
                        #Only Version is NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -ReferenceName $($extension.ReferenceName) -PublicConfiguration '$($extension.PublicConfiguration)'" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -ReferenceName $extension.ReferenceName -PublicConfiguration $extension.PublicConfiguration
                    } else {
                        #Version and PublicConfig NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -ReferenceName $($extension.ReferenceName)" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -ReferenceName $extension.ReferenceName 
                    }
                } else {
                    if ($extension.PublicConfiguration -ne $null){
                        #Version and ReferenceName NULL
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher) -PublicConfiguration '$($extension.PublicConfiguration)'" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher -PublicConfiguration $extension.PublicConfiguration
                    } else {
                        #All NULL 
                        $commands += "Set-AzureVMExtension -VM `$NewVM -ExtensionName $($extension.ExtensionName) -Publisher $($extension.Publisher)" 
                        Set-AzureVMExtension -VM $NewVM -ExtensionName $extension.ExtensionName -Publisher $extension.Publisher 
                    }
                }
            }
        }
  
        $commands += "`$deploymentVnetName = '$($deployment.VNetName)'"

        $newVMCommand = "New-AzureVM -Verbose -ServiceName " + $CloudService + " -VMs `$NewVM"

        #
        # Configure settings that only apply to the first VM
        #
        if ($i -eq "0") {
            if ($internalLB) {
                if ($internalLB.IPAddress) {
                    $commands += "`$internalLBConfig = New-AzureInternalLoadBalancerConfig -InternalLoadBalancerName '$($internalLB.InternalLoadBalancerName)' -SubnetName '$($internalLB.SubnetName)' -StaticVNetIPAddress $($internalLB.IPAddress) "
                    $internalLBConfig = New-AzureInternalLoadBalancerConfig -InternalLoadBalancerName $internalLB.InternalLoadBalancerName -SubnetName $internalLB.SubnetName -StaticVNetIPAddress $internalLB.IPAddress 
                } else {
                    $commands += "`$internalLBConfig = New-AzureInternalLoadBalancerConfig -InternalLoadBalancerName '$($internalLB.InternalLoadBalancerName)' -SubnetName '$($internalLB.SubnetName)'" 
                    $internalLBConfig = New-AzureInternalLoadBalancerConfig -InternalLoadBalancerName $internalLB.InternalLoadBalancerName -SubnetName $internalLB.SubnetName 
                }
                $newVMCommand += " -InternalLoadBalancerConfig `$internalLBConfig"
                    
            }
    
            if ($deployment.VNetName) {
               $newVMCommand += " -VNetName `$deploymentVnetName" 
            }

            if ($reservedIPName) {
               $newVMCommand += " -ReservedIPName `$reservedIPName" 
            }
        }
        $commands += "Write-Host `"Creating VM $($vm.Name) with size of $NewSize`""
        $commands += $newVMCommand 
        $commands += ""
        if($testMode -eq $false)
        {
            Invoke-Expression -Command $newVMCommand
        }
    }

   
    
} catch {
    write-host "An error occurred while adding the VMs back to the cloud service. Please review out output at " $OutputFile " to retry the steps manually."

    Write-host "Error at script line" $error[0].InvocationInfo.ScriptLineNumber ":" $error[0].InvocationInfo.Line
    
    write-host "Error Details:"
    $_
}


foreach($cmd in $commands)
{
    
    if($CommandOutputFile -ne $null)
    {
        $cmd | Out-File -FilePath $CommandOutputFile -Append 
    }else
    {
        Write-Host $cmd -ForegroundColor Green
    }

}
if($CommandOutputFile -ne $null)
{
    Write-Host "Generated PowerShell scripts saved to file `"$CommandOutputFile`"" -ForegroundColor Green
}
# END  

