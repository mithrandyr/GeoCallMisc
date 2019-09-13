function VerifyStorageActive {
    if(-not (Get-AzureRmContext).Subscription.CurrentStorageAccountName) { throw "Storage Account has not been set, use Set-AzureRmCurrentStorageAccount!" }
}

[scriptblock]$GetAzureBlob = {
    param([Parameter(Mandatory)][string]$BlobName
        , [Parameter(Mandatory)][string]$AzToken
        , [string]$FileName
        , [Parameter(Mandatory)][string]$AccountName
        , [Parameter()][string]$ContainerName = "geocall-deploy-configuration"
    )

    [hashtable]$ht = @{
        Uri = "https://{0}.blob.core.windows.net/{1}/{2}" -f $AccountName, $ContainerName, $BlobName
        Headers = @{
                Authorization = $AzToken
                "x-ms-version" = "2017-11-09"
            }
        UseBasicParsing = $true
    }
    if([string]::IsNullOrWhiteSpace($FileName)) { $FileName = $BlobName }
    Invoke-WebRequest @ht -OutFile $FileName
}

function LoadConfiguration {
    param([Parameter(Mandatory)][string]$EnvSuffix
        , [Parameter(Mandatory)][pscredential]$AzCredential)
    
        $ErrorActionPreference = "Stop"
    [string]$ConfigFileName = "geocall{0}.json" -f $EnvSuffix.ToLower()
    [string]$OutFile = Join-Path ([system.io.path]::GetTempPath()) $ConfigFileName
    &$GetAzureBlob -BlobName $ConfigFileName -FileName $OutFile -AzToken (Get-AzureToken -ResourceName Storage -AzCredential $AzCredential)
    $result = Get-Content -Path $OutFile -Raw | ConvertFrom-Json
    Remove-Item -Force -Path $OutFile

    $result
}

function DeployGCPosh {
    [cmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline)][System.Management.Automation.Runspaces.PSSession]$RemoteSession
        , [Parameter(Mandatory)][string]$DriveLetter
        , [Parameter()][switch]$Force
    )
    $ErrorActionPreference = "Stop"

    [string]$gcPoshPath = "{0}:\GCPosh" -f $DriveLetter
    if($Force) {
        Write-Verbose "Force parameter set, removing GCPosh before deploying..."    
        Invoke-Command -Session $RemoteSession -ScriptBlock {
            if(Test-Path -Path $using:gcPoshPath -PathType Container) {
                if($pwd.Path -eq $using:gcPoshPath) { Set-Location ".." }
                Remove-Item -Path $using:gcPoshPath -Recurse -Force
            }
        }
    }

    Write-Verbose "Downloading GCPosh from Azure Storage and installing..."
    Invoke-Command -Session $RemoteSession -ScriptBlock {
        $data = $null
        if(Test-Path -Path $using:gcPoshPath) {
            Import-Module $using:gcPoshPath -Force
            $data = Get-GCPVariable
            If($pwd.path -eq $using:gcPoshPath) { Set-Location ".."}
            Remove-Item $using:gcPoshPath -Recurse -Force
        }

        [string]$destArchive = "{0}:\gcposh.zip" -f $using:DriveLetter
        [scriptblock]$GetAzureBlob = [scriptblock]::Create($using:GetAzureBlob)
        &$GetAzureBlob -BlobName "gcposh.zip" -FileName $destArchive -AzToken (Get-AzureToken -ResourceName Storage -AsToken)
        New-Item -Path $using:gcPoshPath -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $destArchive -DestinationPath $using:gcPoshPath -Force | Out-Null
        Remove-item -Path $destArchive -Force

        Import-Module $using:gcPoshPath -Force
        if($data) { $data | Set-GCPVariable -Persist }
        Remove-Variable data
    }

    Write-Verbose "Finished!"
}

Export-ModuleMember -Function LoadConfiguration, DeployGCPosh