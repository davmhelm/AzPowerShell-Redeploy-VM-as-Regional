# Copyright (c) Microsoft Corporation.
# MIT License
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#Requires -Version 7.0
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="4.1.0" }
#Requires -Modules @{ ModuleName="Az.Compute"; ModuleVersion="9.2.0" }
#Requires -Modules @{ ModuleName="Az.Network"; ModuleVersion="7.15.1" }
#Requires -Modules @{ ModuleName="Az.Resources"; ModuleVersion="7.10.0" }
#Requires -Modules @{ ModuleName="Az.Storage"; ModuleVersion="8.3.0" }

Param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $SourceVm,
    [Parameter(Mandatory=$false)]
    [string] $DiskNameSuffix = $( Get-Date -Format "yyyyMMddHHmmss" -AsUTC )
)

$ErrorActionPreference = 'Stop'

# Suppress warnings as of Az.Resources v7.10.0
Update-AzConfig -DisplayBreakingChangeWarning $false -AppliesTo Az.Resources -Scope Process | Out-Null

try {
    Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Checking zonal deployment"
    if ( $SourceVm.Zones.Count -gt 0 )
    {
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Confirmed resides in logical zone $($SourceVm.Zones), continuing"

        # Change DeleteOption on disks and NICs on source VM
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Ensuring Disk and NIC delete option is 'Detach'"
        $SourceVm.StorageProfile.OsDisk.DeleteOption = 'Detach'
        $SourceVm.StorageProfile.DataDisks | ForEach-Object { $_.DeleteOption = 'Detach' }
        $SourceVm.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.DeleteOption = 'Detach' }
        $SourceVm | Update-AzVM | Out-Null

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating replacement regional VM config"
        ( $DestVmConfig = New-AzVMConfig -VMName $SourceVm.Name `
                -VMSize $SourceVm.HardwareProfile.VmSize `
                -DiskControllerType $SourceVm.StorageProfile.DiskControllerType `
                -HibernationEnabled $SourceVm.AdditionalCapabilities.HibernationEnabled `
        ) | Out-Null

        # Set properties for destination VM config that are easier to manipulate through direct assignment
        if ( $null -ne $SourceVm.LicenseType ) {
            $DestVmConfig.LicenseType = $SourceVm.LicenseType
        }
        
        $DestVmConfig.AvailabilitySetReference = $null
        $DestVmConfig.DiagnosticsProfile = $SourceVm.DiagnosticsProfile
        $DestVmConfig.AdditionalCapabilities.UltraSSDEnabled = $SourceVm.AdditionalCapabilities.UltraSSDEnabled 
        $DestVmConfig.SecurityProfile = $SourceVm.SecurityProfile
        $DestVmConfig.UserData = $SourceVm.UserData
        $DestVmConfig.Tags = $SourceVm.Tags
        $DestVmConfig.Zones = $null # Recommend explicitly defining this to create a regional VM, as opposed to a zonal VM
        
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Stopping source VM before checking if disks are zonal, which will require snapshots"
        $SourceVm | Stop-AzVM -Force | Out-Null

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Checking source VM OS Disk for need of snapshot"
        # Check OS Disk zonality and update destination config
        $SourceVmOsDiskRef = Get-AzResource -ResourceId $SourceVm.StorageProfile.OsDisk.ManagedDisk.Id
        $SourceVmOsDisk = Get-AzDisk -ResourceGroupName $SourceVmOsDiskRef.ResourceGroupName -DiskName $SourceVmOsDiskRef.Name

        if ( $SourceVmOsDisk.Zones.Count -gt 0 ) # Does it matter if .Sku.Name matches Standard_LRS, Premium_LRS, StandardSSD_LRS? 
        {
            $OsDiskSnapshotName = "$($SourceVmOsDisk.Name)-snapshot-$DiskNameSuffix" # must be 80 characters or less
            if ($OsDiskSnapshotName.Length -gt 80 ) 
            {
                throw New-Object System.ArgumentException -ArgumentList ("Disk snapshot names must be 80 characters or less, got length $($OsDiskSnapshotName.Length); try a shorter disk name suffix. Source disk name is `"$($SourceVmOsDisk.Name)`", length $($SourceVmOsDisk.Name.Length); snapshot suffix is `"-snapshot-$DiskNameSuffix`", length $(Measure-Object "-snapshot-$DiskNameSuffix").","DiskNameSuffix") 
            }
            $DestOsDiskName = "$($SourceVmOsDisk.Name)-$DiskNameSuffix" # must be 80 characters or less
            if ($DestOsDiskName.Length -gt 80 ) 
            {
                throw New-Object System.ArgumentException -ArgumentList ("Disk names must be 80 characters or less, got length $($DestOsDiskName.Length); try a shorter disk name suffix. Source disk name is `"$($SourceVmOsDisk.Name)`", length $($SourceVmOsDisk.Name.Length); snapshot suffix is `"-snapshot-$DiskNameSuffix`", length $(Measure-Object $DiskNameSuffix)","DiskNameSuffix") 
            }

            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Source VM OS Disk resides in Zone $($SourceVmOsDisk.Zones[0]) - creating snapshot `"$OsDiskSnapshotName`""
            $SourceVmOsDiskSnapshotConfig = New-AzSnapshotConfig -SourceUri $SourceVmOsDisk.Id -Location $SourceVm.Location -CreateOption Copy -SkuName $SourceVmOsDisk.Sku.Name
            $SourceVmOsDiskSnapshot = New-AzSnapshot -Snapshot $SourceVmOsDiskSnapshotConfig -SnapshotName $OsDiskSnapshotName -ResourceGroupName $SourceVmOsDisk.ResourceGroupName
            
            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating disk `"$DestOsDiskName`" from snapshot `"$OsDiskSnapshotName`""
            $DestVmOsDiskConfig = New-AzDiskConfig -SkuName $SourceVmOsDisk.Sku.Name -Location $SourceVmOsDisk.Location -CreateOption Copy -SourceResourceId $SourceVmOsDiskSnapshot.Id -DiskSizeGB $SourceVmOsDisk.DiskSizeGB
            $DestVmOsDisk = New-AzDisk -Disk $DestVmOsDiskConfig -ResourceGroupName $SourceVmOsDisk.ResourceGroupName -DiskName $DestOsDiskName
            
            # Add Source object's tags to destination objects, if not empty
            if ( $SourceVmOsDisk.Tags.Count -gt 0 )
            {
                $SourceVmOsDiskSnapshot.Tags = $SourceVmOsDisk.Tags
                $SourceVmOsDiskSnapshot | Update-AzSnapshot | Out-Null
                $DestVmOsDisk.Tags = $SourceVmOsDisk.Tags
                $DestVmOsDisk | Update-AzDisk | Out-Null
            }

            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Attaching new OS disk `"$DestOsDiskName`" from snapshot of Source VM to destination VM"
            if ( $SourceVm.StorageProfile.OsDisk.OsType -eq "Windows" )
            {
                Set-AzVMOSDisk -VM $DestVmConfig -Name $DestVmOsDisk.Name -CreateOption Attach -ManagedDiskId $DestVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Windows | Out-Null
            }
            else 
            {
                Set-AzVMOSDisk -VM $DestVmConfig -Name $DestVmOsDisk.Name -CreateOption Attach -ManagedDiskId $DestVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Linux | Out-Null
            }
        }
        else # VM OS Disk is ZRS, or is regional already? Just attach the existing one
        {
            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | OS Disk can be re-used, attaching source VM OS Disk to destination VM"
            if ( $SourceVm.StorageProfile.OsDisk.OsType -eq "Windows" )
            {
                Set-AzVMOSDisk -VM $DestVmConfig -Name $SourceVmOsDisk.Name -CreateOption Attach -ManagedDiskId $SourceVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Windows | Out-Null
            }
            else 
            {
                Set-AzVMOSDisk -VM $DestVmConfig -Name $SourceVmOsDisk.Name -CreateOption Attach -ManagedDiskId $SourceVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Linux | Out-Null
            }
        }

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Checking source VM Data Disk(s)"
        # Check Data Disk(s) zonality and update destination config
        foreach ( $SourceVmDataDisk in $SourceVm.StorageProfile.DataDisks )
        {

            $SourceVmDataDiskRef = Get-AzResource -ResourceId $SourceVmDataDisk.ManagedDisk.Id
            $SourceDataDisk = Get-AzDisk -ResourceGroupName $SourceVmDataDiskRef.ResourceGroupName -DiskName $SourceVmDataDiskRef.Name

            if ( $SourceDataDisk.Zones.Count -gt 0 ) 
            {
                $DataDiskSnapshotName = "$($SourceDataDisk.Name)-snapshot-$DiskNameSuffix" # must be 80 characters or less
                if ($DataDiskSnapshotName.Length -gt 80 ) 
                {
                    throw New-Object System.ArgumentException -ArgumentList ("Disk snapshot names must be 80 characters or less, got length $($DataDiskSnapshotName.Length); try a shorter disk name suffix. Source disk name is `"$($SourceDataDisk.Name)`", length $($SourceDataDisk.Name.Length); snapshot suffix is `"-snapshot-$DiskNameSuffix`", length $(Measure-Object "-snapshot-$DiskNameSuffix").","DiskNameSuffix") 
                }

                $DestDataDiskName = "$($SourceDataDisk.Name)-$DiskNameSuffix" # must be 80 characters or less
                if ($DestDataDiskName.Length -gt 80 ) 
                {
                    throw New-Object System.ArgumentException -ArgumentList ("Disk names must be 80 characters or less, got length $($DestDataDiskName.Length); try a shorter disk name suffix. Source disk name is `"$($SourceDataDisk.Name)`", length $($SourceDataDisk.Name.Length); snapshot suffix is `"-snapshot-$DiskNameSuffix`", length $(Measure-Object $DiskNameSuffix)","DiskNameSuffix") 
                }

                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Source VM Data Disk LUN $($SourceVmDataDisk.Lun) resides in Zone $($SourceDataDisk.Zones[0]) - creating snapshot `"$DataDiskSnapshotName`""
                $SourceDataDiskSnapshotConfig = New-AzSnapshotConfig -SourceUri $SourceDataDisk.Id -Location $SourceVm.Location -CreateOption Copy -SkuName $SourceDataDisk.Sku.Name
                $SourceDataDiskSnapshot = New-AzSnapshot -Snapshot $SourceDataDiskSnapshotConfig -SnapshotName $DataDiskSnapshotName -ResourceGroupName $SourceDataDisk.ResourceGroupName

                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating disk `"$DestDataDiskName`" from snapshot `"$DataDiskSnapshotName`""
                $DestDataDiskConfig = New-AzDiskConfig -SkuName $SourceDataDisk.Sku.Name -Location $SourceDataDisk.Location -CreateOption Copy -SourceResourceId $SourceDataDiskSnapshot.Id -DiskSizeGB $SourceDataDisk.DiskSizeGB
                $DestDataDisk = New-AzDisk -Disk $DestDataDiskConfig -ResourceGroupName $SourceDataDisk.ResourceGroupName -DiskName $DestDataDiskName

                # Add Source object's tags to destination objects, if not empty
                if ( $SourceDataDisk.Tags.Count -gt 0 )
                {
                    $SourceDataDiskSnapshot.Tags = $SourceDataDisk.Tags
                    $SourceVmDataDiskSnapshot | Update-AzSnapshot | Out-Null
                    $DestDataDisk.Tags = $SourceDataDisk.Tags
                    $DestDataDisk | Update-AzDisk | Out-Null
                }

                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Attaching new data disk `"$DestDataDiskName`" from snapshot of source VM Data Disk LUN $($SourceVmDataDisk.Lun) to destination VM"
                Add-AzVMDataDisk -VM $DestVmConfig -Name $DestDataDisk.Name -CreateOption Attach -ManagedDiskId $DestDataDisk.Id -Caching $SourceVmDataDisk.Caching -Lun $SourceVmDataDisk.Lun -DiskSizeInGB $SourceVmDataDisk.DiskSizeGB -DeleteOption Detach | Out-Null
            }
            else # Data Disk is ZRS, or is regional already? Just attach the existing one
            {
                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Data Disk LUN $($SourceVmDataDisk.Lun) can be re-used, attaching source VM Data Disk to destination VM"
                Add-AzVMDataDisk -VM $DestVmConfig -Name $SourceVmDataDisk.Name -CreateOption Attach -ManagedDiskId $SourceVmDataDisk.ManagedDisk.Id -Caching $SourceVmDataDisk.Caching -Lun $SourceVmDataDisk.Lun -DiskSizeInGB $SourceVmDataDisk.DiskSizeGB -DeleteOption Detach | Out-Null
            }
        }

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Attaching source VM NICs to destination VM"
        # Add NIC to destination VM
        foreach ( $VmNic in $SourceVm.NetworkProfile.NetworkInterfaces ) {	
            if ( $VmNic.Primary -eq "True" )
            {
                Add-AzVMNetworkInterface -VM $DestVmConfig -Id $VmNic.Id -Primary -DeleteOption Detach | Out-Null
            }
            else
            {
                Add-AzVMNetworkInterface -VM $DestVmConfig -Id $VmNic.Id -DeleteOption Detach | Out-Null
            }
        }

        # Delete source VM
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | WARNING - Deleting source Zonal VM"
        Remove-AzVM -Name $SourceVm.Name -ResourceGroupName $SourceVm.ResourceGroupName -Force | Out-Null

        # Create replacement VM
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating destination Regional VM"
        New-AzVM -ResourceGroupName $SourceVm.ResourceGroupName -Location $SourceVm.Location -VM $DestVmConfig -DisableBginfoExtension | Out-Null

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Finished"
    }
    else 
    {
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Not Zonal, skipping"
    }
}
catch 
{
    Write-Output "An error occurred during VM recreation:"
    Write-Output $_.ScriptStackTrace
    Write-Output $_
}
