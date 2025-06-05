# PowerShell Sample - Redeploy Zonal Azure VM as Regional VM

## Intro

Why would I want to do this? Though rare, at this time (2025 June) there are use cases that do not benefit from the use of zonally aligning the VM. If you're using this script, it is assumed that you have an understanding of what your specific use case(s) are.

### Example use for one VM

```PowerShell
Connect-AzAccount
$VmName = "Virtual-Machine-Name"
$RgName = "Resource-Group-Name"
$vm = Get-AzVM -Name $VmName -ResourceGroupName $RgName
./redeploy-as-regional-vm.ps1 -SourceVm $vm -Verbose
```

### Example use for multiple VMs in a Resource Group

```PowerShell
Connect-AzAccount
$DiskSuffix = "MyJobName-$( Get-Date -Format "yyyyMMddHHmmss" -AsUTC )" # Use this to keep disk suffixes consistent in parallel execution
$RgName = "Resource-Group-Name"
Get-AzVm -ResourceGroupName $RgName | ForEach-Object -Parallel {
    ./redeploy-as-regional-vm.ps1 -SourceVm $_ -DiskNameSuffix ${Using:DiskSuffix} -Verbose 4>&1 # need Verbose stream output redirection to display logging inside of parallel execution
} -ThrottleLimit 5
```
