<#
.SYNOPSIS
Boots a system with WinPE with WMI, Network and PowerShell. 

 .DESCRIPTION
 The script has two options: USB or Network sourced 
 
 .NOTES
#>

<#
 #<<<<<<<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
 #This part was added to allow local copy from an IIS server
 # with an invalid certificate. remove for production use!
 #<<<<<<<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
 Add-Type @"
 using System;
 using System.Net;
 using System.Net.Security;
 using System.Security.Cryptography.X509Certificates;
 public class ServerCertificateValidationCallback
 {
     public static void Ignore()
     {
         ServicePointManager.ServerCertificateValidationCallback += 
             delegate
             (
                 Object obj, 
                 X509Certificate certificate, 
                 X509Chain chain, 
                 SslPolicyErrors errors
             )
             {
                 return true;
             };
     }
 }
"@
[ServerCertificateValidationCallback]::Ignore();
#<<<<<<<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
#>

[cmdletbinding()]
    param (
         [parameter(Mandatory = $false)]
        [string]$ShareUsername,

        [parameter(Mandatory = $false)]
        [string]$SharePassword,

        [parameter(Mandatory = $false)]
        [string]$NetworkShare,

        [parameter(Mandatory = $false)]
        [string]$CustomGitLocation,

        [parameter(Mandatory = $false)]
        [string]$CustomGitBranch,

        [parameter(Mandatory = $false)]
        [string]$WIMDeployment
    )

# Define Regex for Password Complexity - needs to be at least 12 characters, with at least 1 upper case, 1 lower case, 1 number and 1 special character
$regex = @"
(?=^.{12,123}$)((?=.*\d)(?=.*[A-Z])(?=.*[a-z])|(?=.*\d)(?=.*[^A-Za-z0-9])(?=.*[a-z])|(?=.*[^A-Za-z0-9])(?=.*[A-Z])(?=.*[a-z])|(?=.*\d)(?=.*[A-Z])(?=.*[^A-Za-z0-9]))^.*
"@

#If specified, it will go to the network share to download the Cloudbuilder.vhdx..
#Username and password for network
$version="201909049"

## START SCRIPT
$NETWORK_WAIT_TIMEOUT_SECONDS = 120
$DISMUpdate=$false
$global:logname = $null

 If (!(test-path x:\))    {
     $LogDriveLetter='.'
 }else{
     $LogDriveLetter='X:'
 }
 $global:logname = ($LogDriveLetter + "\ScriptDeployment.log") 

 #Check if PowerShell Version is up to date.. (for Win2012R2 installs)
 If (!($PSVersionTable.PSVersion.Major -ge 5))  {
     Write-Host "Powershell version is not to up date... please install update"
     write-host "https://www.microsoft.com/en-us/download/details.aspx?id=50395"
 exit
 }
 
 $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
 $winPEStartTime = (Get-Date).ToString('yyyy/MM/dd HH:mm:ss')
 $ScriptVersion=(Get-Item .\PrepareDeployment.ps1).LastWriteTime
 Import-Module "$PSScriptRoot\PrepareDeployment.psm1" -Force
 cls
 write-host ""
write-host ""
write-host "                               _____        __                                " -ForegroundColor Green
write-host "     /\                       |_   _|      / _|                               " -ForegroundColor Yellow
write-host "    /  \    _____   _ _ __ ___  | |  _ __ | |_ _ __ __ _   ___ ___  _ __ ___  " -ForegroundColor Red
write-host "   / /\ \  |_  / | | | '__/ _ \ | | | '_ \|  _| '__/ _' | / __/ _ \| '_ ' _ \ " -ForegroundColor Cyan
write-host "  / ____ \  / /| |_| | | |  __/_| |_| | | | | | | | (_| || (_| (_) | | | | | |" -ForegroundColor DarkCyan
write-host " /_/    \_\/___|\__,_|_|  \___|_____|_| |_|_| |_|  \__,_(_)___\___/|_| |_| |_|" -ForegroundColor Magenta
write-host "                                                                              "
 write-host "                    Welcome to the Network deployment script " -foregroundColor Yellow
 write-host ""

 $ActiveLog = ActivateLog
 $Info=ComputerInfo
 $HostManufacturer=$Info.Manufacturer
 $HostModel=$Info.Model
 $DecomposedShare=$NetworkShare.split("\")
 $ShareRoot = ("\\" + $DecomposedShare[2] + "\" + $DecomposedShare[3])
 $sourceVHDFolder=$NetworkShare.Replace($ShareRoot,"")
 
 Write-LogMessage -Message "Script version: $version"
 Write-LogMessage -Message "Running on a $HostManufacturer $HostModel"
#System Validation checks
    
    CheckCPU
     $HyperV=CheckHyperVSupport
        If ($HyperV){    
            Write-AlertMessage -Message "CPU does not meet Hyper-V requirements.. "
         }
         else
         {
            Write-LogMessage -Message "CPU Virtualization is supported and enabled"
         }
    
    $totalMemoryInGB=CheckRam
        if ($totalMemoryInGB -gt 1)   {
            Write-LogMessage -Message "System has $totalMemoryInGB Gb of memory available"
            Exit-PSHostProcess
        }

   

 $IsWinPe = HostIsWinPE
 If (!($IsWinPe)){       
        Write-AlertMessage -Message "You are running this script inside a Windows environment"
        Exit-PSSession

 }

#For WIM file deployments - manual override for manual deployment of WIM file

    #starting network capabilities in WinPE
    Set-WinPEDeploymentPrerequisites 

    #info for IP addresses
    $IpInfo=GetIPInfo
    $NetArray=$IpInfo | Where { $_.IPAddress } 

    If ($NetArray.count -eq 0){
        Write-AlertMessage -Message "No network found, local mode only"
    }
    else {
        #THIS IS THE ENTIRE NETWORK PART
        ForEach ($Net in $NetArray) {
            $IPaddress= $Net| Select -Expand IPAddress | Where { $_ -notlike '*:*' }
            $Gateway= $Net | select -expand DefaultIPGateway
            $IPSubnet = $net | select -expand IPSubnet | where {$_ -like '255*'}
            $DHCPserver = $net | select -expand DHCPServer
            $DNSServers = $Net | select -expand DNSServerSearchOrder
            $DNSDomain = $Net | select -expand DNSDomain
            Write-LogMessage -Message "Assigned IPv4 IP: $IPAddress"
            Write-LogMessage -Message "Assigned SubMask: $IPSubnet"
            Write-LogMessage -Message "Assigned Gateway: $Gateway"
            ForEach ($DNS in $DNSServers) {
                Write-LogMessage -Message "Assigned DNS Srv: $DNSServers"
            }
            ForEach ($Domain in $DNSDomain) {
            Write-LogMessage -Message "Assigned Suffix : $Domain"
            }
            Write-LogMessage -Message "Net DHCP Server : $DHCPServer"
            
        }


        

        Write-AlertMessage -Message "Provide fileshare to be mounted in Z drive (eg. \\172.16.5.10\Share)"
        $ShareRoot = read-host 
        Write-AlertMessage -Message "Please provide username and password for share"
        $Credential=get-credential  -Message "Please provide username and password for share" 

        $DriveLetter = "Z"
        Write-LogMessage -Message ("Validating network access to " + $ShareRoot.split('\')[2]) 
        If (test-connection $ShareRoot.split('\')[2]) {
        Write-LogMessage -Message "Creating network drive $DriveLetter to source share"
            If (test-path z:\) {
                Write-LogMessage -Message "Network drive already mounted"
            }else{
                New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $ShareRoot -Credential $Credential -Persist -Scope Global
                }
            }
    }


    Write-LogMessage -Message "Creating Drive Preparation Script - diskpart"
    $DiskParkFile=New-Item ($LogDriveLetter + '\DiskClear.txt')
    Add-Content $DiskParkFile 'select disk 0'
    Add-Content $DiskParkFile "clean"
    Add-Content $DiskParkFile "create partition primary size=100"
    Add-Content $DiskParkFile "format quick fs=ntfs label=System"
    Add-Content $DiskParkFile "assign letter=S"
    Add-Content $DiskParkFile "active"
    Add-Content $DiskParkFile "create partition primary"
    Add-Content $DiskParkFile "format quick fs=ntfs label=Windows"
    Add-Content $DiskParkFile "assign letter=W"


    $SetBootBCE=New-Item ($LogDriveLetter + '\setboot.bat')
    Add-Content $SetBootBCE 'W:\Windows\System32\bcdboot W:\Windows /s S:'

    $ApplyImage=New-Item ($LogDriveLetter + '\ApplyImage.bat')
    Add-Content $ApplyImage 'dism /Apply-Image /ImageFile:Z:\install.wim /Index:1 /ApplyDir:W:\ '
   
    #Need to deploy 
        Write-host "- Welcome to the WinPE Deployment - "
        write-host "   To partition/format the drive type diskpart"
        Write-host "   type: diskpart /s DiskClear.txt for automated version on disk 0"
        Write-host ""
        Write-host "   To deploy your wim file, type:"
        Write-host "    Dism /Apply-Image /ImageFile:Z:\install.wim /Index:1 /ApplyDir:W:\ "
        Write-host "    - or type ApplyImage for the default setting"
        Write-host ""
        Write-host "   then to activate boot for the system drive"
        Write-host "     W:\Windows\System32\bcdboot W:\Windows /s S:"
        Write-host "    - or run setboot.bat for the default setting"

        Write-host ""
        exit-PSHostProcess


    #End of override for wim deployments



