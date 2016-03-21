# Parse Params:
[CmdletBinding()]
Param(
    [Parameter(
        Position=1,
        Mandatory=$True,
        HelpMessage="What is the name of the virtual machine (or machines) to be created?"
        )]
        [string]$VMMachineName,

    [Parameter(
        Position=2,
        Mandatory=$False,
        HelpMessage="What Generation VM should be created?  Valid values are 1 (legacy) and 2 (UEFI, requires Win8/Server 2012 or higher!) - default is 1."
        )]
        [ValidateRange(1,2)]
        [int16]$Generation = '1',
    
    [Parameter(
        Position=3,
        Mandatory=$False,
        HelpMessage="Define the memory size for the VM(s). The minimum is 1GB, max is 64GB, default is 2GB."
        )]
        [ValidateRange(1GB,64GB)]
        [int64]$vMemory = '2147483648',

    [Parameter(
        Position=4,
        Mandatory=$False,
        HelpMessage="Dynamic Memory enabled, true or false."
        )]
        [ValidateSet($True, $False)]
        [bool]$DynamicMem = $True,
    
    [Parameter(
        Position=5,
        Mandatory=$False,
        HelpMessage="How many vCPUs should each machine be configured with? The minimum is 1, max is 8, default is 2."
        )]
        [ValidateRange(1,8)]
        [int]$vCPU = '2',
    
    [Parameter(
        Position=6,
        Mandatory=$False,
        HelpMessage="What virtual switch should the default NIC be bound to?  External, Internal, Corp - default is 'Internal'."
        )]
        [ValidateSet('External','Internal','Corp')]
        [string]$vSwitch = 'Internal',

    [Parameter(
        Position=7,
        Mandatory=$False,
        HelpMessage="Should the vNIC be Synthetic or Legacy (for PXE booting)?  Default is 'Synthetic' - note this param is ignored if 'Generation' param set to '2'."
        )]
        [ValidateSet('Synthetic','Legacy')]
        [string]$vNIC = 'Synthetic',

    [Parameter(
        Position=8,
        Mandatory=$False,
        HelpMessage="VLAN ID?"
        )]
        [int]$VlanId,

    [Parameter(
        Position=9,
        Mandatory=$False,
        HelpMessage="Create VHD or VHDX?"
        )]
        [ValidateSet('vhd','vhdx')]
        [string]$VHDType = 'vhdx',

        [Parameter(
        Position=9,
        Mandatory=$False,
        HelpMessage="Is this a Linux VM? (default is $False)"
        )]
        [ValidateSet($True, $False)]
        [bool]$LinuxVM = $False
    )


# Thanks to Tome Tanasovski:
# http://powertoe.wordpress.com/2012/03/13/powerbits-8-opening-a-hyper-v-console-from-powershell/
function Connect-VM {
	param(
		[Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
		[String[]]$ComputerName
	)
	PROCESS {
		foreach ($name in $computername) {
			vmconnect localhost $name
		}
	}
}


# Check if 'Legacy' passed for vNIC, and set $vNICType accordingly:
$vNICType = $False
If ($vNIC -eq 'Legacy')
{
    $vNICType = $True
}


# Edit default VM path as necessary, these are my usual defaults:
$VMPath = "C:\VM"
$VHDPath = $VMPath + "\" + $VMMachineName + "\Virtual Hard Disks\" + $VMMachineName + "." + $VHDType


# Check if VM exists and remove:
$VMExist = Get-VM -Name $VMMachineName -ErrorAction SilentlyContinue
If ($VMExist)
{
    If ($VMExist.State -eq "Off")
    {
        Write-Host "Deleting virtual machine $VMMachineName in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep 5
        Remove-VM $VMMachineName -Force -Confirm:$False -ErrorAction Stop
    }
    Else
    {
        Write-Host "Stopping virtual machine $VMMachineName in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep 5
        Stop-VM -Name $VMMachineName -TurnOff -Force -Confirm:$false -ErrorAction Stop
        Write-Host "Deleting virtual machine $VMMachineName in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep 5
        Remove-VM $VMMachineName -Force -Confirm:$False -ErrorAction Stop
    }
}


# Check if $VMMachineName folder exists and remove:
If (Test-Path -Path "$VMPath\$VMMAchineName")
{
    Write-Host "Deleting existing data in path $VMPath\$VMMachineName in 5 seconds..." -ForegroundColor Yellow
    Start-Sleep 5
    Remove-Item -Path "$VMPath\$VMMachineName" -Recurse -Force -Confirm:$False -ErrorAction Stop
}


# Let's go:
Write-Host ""
Write-Host "Creating virtual machine" $VMMachineName "..." -ForegroundColor Cyan
Write-Host ""


# Create the new VM, including generation type - attach no VHD yet:
New-VM -Path $VMPath -Generation $Generation -MemoryStartupBytes $vMemory -Name $VMMachineName -NoVHD | Out-Null


# The default adapter is only created as legacy if you specify it as the
# default boot adapter, so remove and re-create later:
Remove-VMNetworkAdapter -VMName $VMMachineName -Name "Network Adapter"


# Configure VM-specific CPU, vMem, and VHD - if Linux, set VHDX block size to 1MB:
If ($DynamicMem -eq $True)
{
    Set-VMMemory $VMMachineName -DynamicMemoryEnabled $True -MinimumBytes 768MB -StartupBytes 1024MB -MaximumBytes $vMemory -Priority 80 -Buffer 20
}
Else
{
    Set-VMMemory $VMMachineName -DynamicMemoryEnabled $False
}
Set-VMProcessor $VMMachineName -Count $vCPU

If ($LinuxVM -eq $True)
{
    New-VHD -Dynamic -Path $VHDPath -SizeBytes 127GB –BlockSizeBytes 1MB | Out-Null
}
Else
{
    New-VHD -Dynamic -Path $VHDPath -SizeBytes 127GB | Out-Null
}
Add-VMHardDiskDrive -VMName $VMMachineName -Path $VHDPath


# Configre Gen1 vs Gen2-specific features:
If ($Generation -eq '1')
{
    Add-VMNetworkAdapter -VMName $VMMachineName -Name "$vSwitch Network" -IsLegacy $vNICType -SwitchName $vSwitch
    Set-VMBios $VMMachineName -StartupOrder @("LegacyNetworkAdapter","CD","IDE","Floppy")
    Set-VMBios $VMMachineName -EnableNumLock
}
else
{
    Add-VMNetworkAdapter -VMName $VMMachineName -Name "$vSwitch Network" -SwitchName $vSwitch

    #Change to Hyper-V module 1.1 - bug in Windows 10/Server 2016
    Remove-Module Hyper-V
    Import-Module Hyper-V -RequiredVersion 1.1 -Force

    Add-VMDvdDrive -VMName $VMMachineName

    #Change back to Hyper-V module 2.0
    Remove-Module Hyper-V
    Import-Module Hyper-V
    
    $DVD = Get-VMDvdDrive -VMName $VMMachineName
    Set-VMFirmware -VMName $VMMachineName –EnableSecureBoot Off -PreferredNetworkBootProtocol IPv4 -FirstBootDevice $DVD
}


# Set the virtual COM port for kernel debugging:
Set-VMComPort -VMName $VMMachineName -Path \\.\pipe\$VMMAchineName -Number 1


# Enable Guest Service Interface Integration (allows copy to/from VM via
# PowerShell):
Enable-VMIntegrationService -VMName $VMMachineName -Name "Guest Service Interface"


# Set VM Start/Stop behavior:
Set-VM -Name $VMMachineName -AutomaticStartAction Nothing -AutomaticStopAction Save


# Configure VLAN if param passed:
If ($VlanId)
{
    Set-VMNetworkAdapterVlan –VMName $VMMachineName –Access –VlanId $VlanId
}


# Uncomment to add an ISO at path $ISO:
#$ISO = '\\Server\share\isoname.iso'
#Set-VMDvdDrive -VMName $VMMachineName -Path $ISO


# Start the VM:
#Write-Host "Starting virtual machine $VMMachineName..." -ForegroundColor Cyan
#Start-Sleep 1
#Start-VM -Name $VMMachineName


# Connect to the VM:
Write-Host "Connecting to virtual machine $VMMachineName..." -ForegroundColor Cyan
Start-sleep 1
Connect-VM $VMMachineName