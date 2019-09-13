<#
.Synopsis
    Deploy GeoCall via PowerShell Remoting.

.Description
    Deploy GeoCall via PowerShell Remoting.

    FULL DEPLOYMENT PROCESS

    Create Azure Environment
    Run this script
    

#>
[cmdletBinding()]
Param(
    [Parameter(Mandatory)][string]$EnvSuffix
    , [Parameter()][string]$ResourceGroupName = "ProdServices"
    , [Parameter(Mandatory)][string]$StorageAccountName
    , [Parameter()][string]$ContainerName = "geocall-deploy-configuration"
    , [Parameter(Mandatory)][string]$StateAbbreviation
    , [Parameter(Mandatory)][string]$StateTitle
    , [Parameter()][string]$GeoCallVersion
    , [Parameter()][pscredential]$Credential
    , [int]$RunStep = 1
    , [switch]$SaveVMCredential
)
$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\GeoCallDeployFunctions.psm1" -Force
Import-Module AzureRM.Profile
Import-Module SimplyCredential -Force

#Read Config data
Write-Host "LoadConfiguration..."
$config = LoadConfiguration -EnvSuffix $EnvSuffix -AzCredential $Credential
if($SaveVMCredential) { New-Credential -UserName $config.VM.User -Password $config.VM.Password | Save-Credential -Name "geocall$envSuffix" -Force }

#setting up environment
Write-Host "Creating PowerShell Remoting Session..."
$rSession = New-AzurePSSession -DnsName $config.PublicIp.DnsName -VmCred (New-Credential -UserName $config.VM.User -Password $config.VM.Password)

Write-Host "DeployGCPosh..."
Invoke-Command -Session $rSession -ScriptBlock { Import-Module SimplySql, SimplyCredential }
if($RunStep -gt 1) { DeployGCPosh -RemoteSession $rSession -DriveLetter $config.VM.DriveLetter }
else { DeployGCPosh -RemoteSession $rSession -DriveLetter $config.VM.DriveLetter -Force }

Write-Host "Running Invoke-GCPDeployment"
#doing install
Invoke-Command -Session $rSession -ScriptBlock {
    $localConfig = $using:Config

    $splat = @{
        RootPath = "{0}:\" -f $localConfig.VM.DriveLetter
        StateAbbreviation = $using:StateAbbreviation
        StateTitle = $using:StateTitle
        AzStorageAccount = $using:StorageAccountName
        AzContainerGeoCallConfiguration = "geocall-config-artifacts"
        AzContainerGeoCallTools = $using:ContainerName
        SqlServerName = $localConfig.Sql.Server
        SqlDatabaseName = $localConfig.Sql.Database
        SqlUserName = $localConfig.Sql.User
        SqlPass = $localConfig.Sql.Password
        PgServerName = $localConfig.Postgres.Server
        PgDatabaseName = $localConfig.Postgres.Database
        PgUserName = $localConfig.Postgres.User
        PgPass = $localConfig.Postgres.Password
        DnsHostName = $localConfig.DnsName
        GeoCallVersion = $using:GeoCallVersion
        BuildType = "Production"
        StartAtStep = $using:RunStep
    }
    Invoke-GCPDeployment @splat
}

$rSession