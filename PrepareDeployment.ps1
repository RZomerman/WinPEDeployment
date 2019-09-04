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
$version="201909043"

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

 Write-LogMessage -Message "Preparing Network WIM File Deployment: $winPEStartTime"
 

 
 Write-LogMessage -Message "Script version: $version"
 Write-LogMessage -Message "Running on a $HostManufacturer $HostModel"
#System Validation checks
    $cores=CheckCPU
        Write-LogMessage -Message "System has a total of $cores logical cores"
 
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

    Write-AlertMessage -Message "Provide fileshare where wim file is located (eg. \\172.16.5.10\Share)"
    $ShareRoot = read-host 
    Write-AlertMessage -Message "Please provide username and password for share"
    $Credential=get-credential 
    Write-AlertMessage -Message "please provide the path to the wim file (eg: \sources\install.wim)"
    $sourceWimFile = read-host 

    $DriveLetter = "Z"
    Write-LogMessage -Message ("Validating network access to " + $ShareRoot)
    If (test-connection $ShareRoot.split('\')[2]) {
    Write-LogMessage -Message "Creating network drive $DriveLetter to source share"
        If (test-path z:\) {
            Write-LogMessage -Message "Network drive already mounted"
        }else{
            New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $ShareRoot -Credential $Credential -Persist -Scope Global
            }
        }
    
    #Need to clean the disks
    #Need to deploy 
        Write-host "To clear the disk and prepare it for the WIM file deployment"
        write-host "type diskpart and execute the following commands:"
        Write-host "---------------------------------"
        Write-host "select disk <>"
        Write-host "clean"
        Write-host "create partition primary size=100"
        Write-host "format quick fs=ntfs label=System"
        Write-host "assign letter=S"
        Write-host "active"
        Write-host "create partition primary"
        Write-host "format quick fs=ntfs label=Windows"
        Write-host "assign letter=W"
        Write-host "---------------------------------"
        Write-host ""
        Write-host "To deploy your wim file, type:"
        Write-host "dism /Apply-Image /ImageFile:Z:\HUB\install.wim /Index:1 /ApplyDir:W:\ W:\Windows\System32\bcdboot W:\Windows /s S:"
        Write-host ""
        Write-host "concluding the script"
        exit-PSHostProcess


    #End of override for wim deployments



