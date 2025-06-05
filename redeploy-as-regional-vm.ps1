# MIT License
# 
# Copyright (c) Microsoft Corporation.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy 
# of this software and associated documentation files (the "Software"), to deal 
# in the Software without restriction, including without limitation the rights 
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
# copies of the Software, and to permit persons to whom the Software is 
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all 
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
# SOFTWARE.

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

# Suppress warnings as of Az.Resources v7.10.0
Update-AzConfig -DisplayBreakingChangeWarning $false -AppliesTo Az.Resources -Scope Process | Out-Null

try {
    Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Checking zonal deployment"
    if ( $SourceVm.Zones.Count -gt 0 )
    {
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Confirmed resides in logical zone $($SourceVm.Zones)"

        # Change DeleteOption on disks and NICs on source VM
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Ensuring Disk and NIC delete option is 'Detach'"
        $SourceVm.StorageProfile.OsDisk.DeleteOption = 'Detach'
        $SourceVm.StorageProfile.DataDisks | ForEach-Object { $_.DeleteOption = 'Detach' }
        $SourceVm.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.DeleteOption = 'Detach' }
        $SourceVm | Update-AzVM | Out-Null

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating replacement regional VM config"
        $destVmConfig = New-AzVMConfig -VMName $SourceVm.Name `
                -VMSize $SourceVm.HardwareProfile.VmSize `
                -DiskControllerType $SourceVm.StorageProfile.DiskControllerType `
                -HibernationEnabled $SourceVm.AdditionalCapabilities.HibernationEnabled

        # Set properties for destination VM config that are easier to manipulate through direct assignment
        if ( $null -ne $SourceVm.LicenseType ) {
            $destVmConfig.LicenseType = $SourceVm.LicenseType
        }
        
        $destVmConfig.AvailabilitySetReference = $null
        $destVmConfig.DiagnosticsProfile = $SourceVm.DiagnosticsProfile
        $destVmConfig.AdditionalCapabilities.UltraSSDEnabled = $SourceVm.AdditionalCapabilities.UltraSSDEnabled 
        $destVmConfig.SecurityProfile = $SourceVm.SecurityProfile
        $destVmConfig.UserData = $SourceVm.UserData
        $destVmConfig.Tags = $SourceVm.Tags
        $destVmConfig.Zones = $null # Recommend explicitly defining this to create a regional VM, as opposed to a zonal VM
        
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Stopping source VM before checking disks potentially needing snapshots"
        $SourceVm | Stop-AzVM -Force | Out-Null

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Checking source VM OS Disk for need of snapshot"
        # Check OS Disk zonality and update destination config
        $sourceVmOsDiskRef = Get-AzResource -ResourceId $SourceVm.StorageProfile.OsDisk.ManagedDisk.Id
        $sourceVmOsDisk = Get-AzDisk -ResourceGroupName $sourceVmOsDiskRef.ResourceGroupName -DiskName $sourceVmOsDiskRef.Name

        if ( $sourceVmOsDisk.Zones.Count -gt 0 ) # Does it matter if .Sku.Name matches Standard_LRS, Premium_LRS, StandardSSD_LRS? 
        {
            $OsDiskSnapshotName = "$($sourceVmOsDisk.Name)-snapshot-$DiskNameSuffix"
            $DestOsDiskName = "$($sourceVmOsDisk.Name)-$DiskNameSuffix"
            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Source VM OS Disk resides in Zone $($sourceVmOsDisk.Zones[0]) - creating snapshot `"$OsDiskSnapshotName`""
            $sourceVmOsDiskSnapshotConfig = New-AzSnapshotConfig -SourceUri $sourceVmOsDisk.Id -Location $SourceVm.Location -CreateOption Copy -SkuName $sourceVmOsDisk.Sku.Name
            $sourceVmOsDiskSnapshot = New-AzSnapshot -Snapshot $sourceVmOsDiskSnapshotConfig -SnapshotName $OsDiskSnapshotName -ResourceGroupName $sourceVmOsDisk.ResourceGroupName
            
            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating disk `"$DestOsDiskName`" from snapshot `"$OsDiskSnapshotName`""
            $destVmOsDiskConfig = New-AzDiskConfig -SkuName $sourceVmOsDisk.Sku.Name -Location $sourceVmOsDisk.Location -CreateOption Copy -SourceResourceId $sourceVmOsDiskSnapshot.Id -DiskSizeGB $sourceVmOsDisk.DiskSizeGB
            $destVmOsDisk = New-AzDisk -Disk $destVmOsDiskConfig -ResourceGroupName $sourceVmOsDisk.ResourceGroupName -DiskName $DestOsDiskName
            
            # Add Source object's tags to destination objects, if not empty
            if ( $sourceVmOsDisk.Tags.Count -gt 0 )
            {
                Write-Verbose "Tags $($sourceVmOsDisk.Tags)"
                $sourceVmOsDiskSnapshot.Tags = $sourceVmOsDisk.Tags
                $sourceVmOsDiskSnapshot | Update-AzSnapshot | Out-Null
                $destVmOsDisk.Tags = $sourceVmOsDisk.Tags
                $destVmOsDisk | Update-AzDisk | Out-Null
            }

            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Attaching new OS disk `"$DestOsDiskName`" from snapshot of Source VM to destination VM"
            if ( $SourceVm.StorageProfile.OsDisk.OsType -eq "Windows" )
            {
                Set-AzVMOSDisk -VM $destVmConfig -Name $destVmOsDisk.Name -CreateOption Attach -ManagedDiskId $destVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Windows
            }
            else 
            {
                Set-AzVMOSDisk -VM $destVmConfig -Name $destVmOsDisk.Name -CreateOption Attach -ManagedDiskId $destVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Linux
            }
        }
        else # VM OS Disk is ZRS, or is regional already? Just attach the existing one
        {
            Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | OS Disk can be re-used, attaching source VM OS Disk to destination VM"
            if ( $SourceVm.StorageProfile.OsDisk.OsType -eq "Windows" )
            {
                Set-AzVMOSDisk -VM $destVmConfig -Name $sourceVmOsDisk.Name -CreateOption Attach -ManagedDiskId $sourceVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Windows
            }
            else 
            {
                Set-AzVMOSDisk -VM $destVmConfig -Name $sourceVmOsDisk.Name -CreateOption Attach -ManagedDiskId $sourceVmOsDisk.Id -Caching $SourceVm.StorageProfile.OsDisk.Caching -DeleteOption Detach -Linux
            }
        }

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Checking source VM Data Disk(s)"
        # Check Data Disk(s) zonality and update destination config
        foreach ( $sourceDataDisk in $SourceVm.StorageProfile.DataDisks )
        {
            if ( $sourceDataDisk.Zones.Count -gt 0 ) 
            {
                $DataDiskSnapshotName = "$($sourceDataDisk.Name)-snapshot-$DiskNameSuffix"
                $DestDataDiskName = "$($sourceDataDisk.Name)-$DiskNameSuffix"
                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Source VM Data Disk LUN $($sourceDataDisk.Lun) resides in Zone $($sourceDataDisk.Zones[0]) - creating snapshot `"$DataDiskSnapshotName`""
                $sourceDataDiskSnapshotConfig = New-AzSnapshotConfig -SourceUri $sourceDataDisk.ManagedDisk.Id -Location $SourceVm.Location -CreateOption Copy -SkuName $sourceDataDisk.Sku.Name
                $sourceDataDiskSnapshot = New-AzSnapshot -Snapshot $sourceDataDiskSnapshotConfig -SnapshotName $DataDiskSnapshotName -ResourceGroupName $sourceDataDisk.ResourceGroupName

                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating disk `"$DestDataDiskName`" from snapshot `"$DataDiskSnapshotName`""
                $destDataDiskConfig = New-AzDiskConfig -SkuName $sourceDataDisk.Sku.Name -Location $sourceDataDisk.Location -CreateOption Copy -SourceResourceId $sourceDataDiskSnapshot.Id -DiskSizeGB $sourceDataDisk.DiskSizeGB
                $destDataDisk = New-AzDisk -Disk $destDataDiskConfig -ResourceGroupName $sourceDataDisk.ResourceGroupName -DiskName $DestDataDiskName

                # Add Source object's tags to destination objects, if not empty
                if ( $sourceDataDisk.Tags.Count -gt 0 )
                {
                    $sourceDataDiskSnapshot.Tags = $sourceDataDisk.Tags
                    $sourceDataDiskSnapshot | Update-AzSnapshot | Out-Null
                    $destDataDisk.Tags = $sourceDataDisk.Tags
                    $destDataDisk | Update-AzDisk | Out-Null
                }

                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Attaching new data disk `"$DestDataDiskName`" from snapshot of source VM Data Disk LUN $($sourceDataDisk.Lun) to destination VM"
                Add-AzVMDataDisk -VM $destVmConfig -Name $destDataDisk.Name -CreateOption Attach -ManagedDiskId $destDataDisk.Id -Caching $sourceDataDisk.Caching -Lun $sourceDataDisk.Lun -DiskSizeInGB $sourceDataDisk.DiskSizeGB -DeleteOption Detach
            }
            else # Data Disk is ZRS, or is regional already? Just attach the existing one
            {
                Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Data Disk LUN $($sourceDataDisk.Lun) can be re-used, attaching source VM Data Disk to destination VM"
                Add-AzVMDataDisk -VM $destVmConfig -Name $sourceDataDisk.Name -CreateOption Attach -ManagedDiskId $sourceDataDisk.ManagedDisk.Id -Caching $sourceDataDisk.Caching -Lun $sourceDataDisk.Lun -DiskSizeInGB $sourceDataDisk.DiskSizeGB -DeleteOption Detach
            }
        }

        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Attaching source VM NICs to destination VM"
        # Add NIC to destination VM
        foreach ( $nic in $SourceVm.NetworkProfile.NetworkInterfaces ) {	
            if ( $nic.Primary -eq "True" )
            {
                Add-AzVMNetworkInterface -VM $destVmConfig -Id $nic.Id -Primary -DeleteOption Detach
            }
            else
            {
                Add-AzVMNetworkInterface -VM $destVmConfig -Id $nic.Id -DeleteOption Detach
            }
        }

        # Delete source VM
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | WARNING - Deleting source Zonal VM"
        Remove-AzVM -Name $SourceVm.Name -ResourceGroupName $SourceVm.ResourceGroupName -Force

        # Create replacement VM
        Write-Verbose -Message "VM $($SourceVm.Name) in ResourceGroup $($SourceVm.ResourceGroupName) | Creating destination Regional VM"
        New-AzVM -ResourceGroupName $SourceVm.ResourceGroupName -Location $SourceVm.Location -VM $destVmConfig -DisableBginfoExtension

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
