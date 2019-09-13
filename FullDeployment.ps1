<#
.Synopsis
    Create Azure environment and install GeoCall.

.Description
    Create Azure environment and install GeoCall.

    Only required params: EnvType, Credential
#>
Param([parameter(mandatory)][ValidateSet("Dev","Test","UAT","Prod","Other")][string]$EnvType
    , [string]$EnvSuffix
    , [string]$AzureLocation = 'eastus'
    , [string]$TimeZone = [System.TimeZone]::CurrentTimeZone.StandardName
    , [parameter(mandatory)][pscredential]$Credential
    , [Parameter()][string]$ResourceGroupName = "ProdServices"
    , [Parameter(Mandatory)][string]$StorageAccountName
    , [Parameter(Mandatory)][string]$ContainerName
    , [Parameter(Mandatory)][string]$StateAbbreviation
    , [Parameter()][version]$GCVersion = "3.2018.1005.29163"
    , [int]$ResumeStep = 1
)

$Timing = [Ordered]@{
    Script = [PSCustomObject]@{
        Deployment = "Full"
        Start = Get-Date
        End = $null
        Elapsed = $null
    }
    Azure = [PSCustomObject]@{
        Deployment = "Azure"
        Start = $null
        End = $null
        Elapsed = $null
    }
    GeoCall = [PSCustomObject]@{
        Deployment = "GeoCall"
        Start = $null
        End = $null
        Elapsed = $null
    }
    GIS = [PSCustomObject]@{
        Deployment = "GIS"
        Start = $null
        End = $null
        Elapsed = $null
    }
} 

if(-not $EnvSuffix) { $EnvSuffix = $EnvType }
$splat = ([hashtable]$PSBoundParameters).Clone()
$splat.Remove("ResumeStep")

$Timing.Azure.Start = Get-Date
& "$PSScriptRoot\AzureDeploy\CreateEnvironment.ps1" @splat
$Timing.Azure.End = Get-Date
$Timing.Azure.Elapsed = $Timing.Azure.End.Subtract($Timing.Azure.Start)

$Timing.GeoCall.Start = Get-Date
$rSession = & "$PSScriptRoot\GeoCallDeploy\DeployGeoCall.ps1" -EnvSuffix $EnvSuffix -GeoCallVersion $GCVersion.ToString() -Credential $Credential -SaveVMCredential -RunStep $ResumeStep
$Timing.GeoCall.End = Get-Date
$Timing.GeoCall.Elapsed = $Timing.GeoCall.End.Subtract($Timing.GeoCall.Start)
<#
$Timing.GIS.Start = Get-Date
Invoke-Command $rSession -ScriptBlock {
    Open-GCPSqlConnection -Type PostGres -ConnectionName src
    Set-SqlConnection -ConnectionName src -Database gisdata
    
    Open-GCPSqlConnection -Type PostGres -ConnectionName dst

    Import-GCPGisData -SrcCN src -DestCN dst
    Reset-GCPGeoCall
}
$Timing.GIS.End = Get-Date
$Timing.GIS.Elapsed = $Timing.GIS.End.Subtract($Timing.GIS.Start)
#>
$Timing.Script.End = Get-Date
$Timing.Script.Elapsed = $Timing.Script.End.Subtract($Timing.Script.Start)

$Timing.Keys | ForEach-Object { $Timing.$_ }