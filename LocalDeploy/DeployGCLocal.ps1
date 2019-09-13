<#
.Synopsis
    Local GeoCall Administrative Script.

.Description
    Local GeoCall Administrative Script.
    Some actions require an active connection to Azure.
        Connect-AzAccount
    
    ACTIONS
    Install-GeoCall = Installs GeoCall, includes drop any existing databases,
        requires valid connection to Azure.
    Deploy-Config-Local = handles copying your configuration over and applying
        customizations; you will still need to run Reset-GCPGeoCall afterwards.
    Reset-Databases = this will drop and recreate the PostGres and MSSQL databases.
    Show-Version = this will show the current version of this file, use this to see
        if you have the latest.
    Apply-Params = this will reset the configuration files with information from
        params.json.
    Clean-Folder = this will cleanup the root folder, removing GCPosh and GeoCall
        subdirectories.
    Update-GCPosh = this will update your version of GCPosh, requires valid
        connection to Azure.
    Reset-MSSQL = this will drop and rebuild the MSSQL database, including
        initializing the databaes and applying configuration.

.Parameter Action
    Default action = Deploy-Config-Local
    Available actions = Install-GeoCall, Deploy-Config-Local, Reset-Databases,
        Show-Version, Apply-Params, Clean-Folder, Update-GCPosh, Reset-MSSQL

.Example
    .\DeployGCLocal.ps1 -Action Deploy-Config-Local
    Calling the action 'Deploy-Config-Local' explicitly, using a named parameter.

.Example
    .\DeployGCLocal.ps1 Deploy-Config-Local
    Calling the action 'Deploy-Config-Local' explicitly, without specifying the parameter.

.Example
    .\DeployGCLocal.ps1
    Calling the action 'Deploy-Config-Local' implicitly, using the default value for -Action.
#>
param([string][ValidateSet("Install-GeoCall"
        , "Deploy-Config-Local"
        , "Reset-Databases"
        , "Show-Version"
        , "Apply-Params"
        , "Clean-Folder"
        , "Update-GCPosh"
        , "Reset-MSSQL")]
    $Action = "Deploy-Config-Local")

if($Action -eq "Show-Version") { Write-Output "2019-08-30 15:39 PM"; return }
elseif($Action -eq "Clean-Folder") {
    $PSScriptRoot |
        Get-ChildItem -Directory |
        Where-Object name -in "GCPosh","GeoCall" |
        Remove-Item -Recurse -Force
    
    Write-Warning "Folder $ScriptRoot has been cleaned of the directories: GCPosh and GeoCall!"
    return
}

$ErrorActionPreference = "Stop"
if(Test-Path "$PSScriptRoot\params.json") { $config = Get-Content -Raw "$PSScriptRoot\params.json" | ConvertFrom-Json }
else {
    Write-Warning "No params.json file found, creating default and opening in VS Code -- edit and rerun!"
    Set-Content -Path "$PSSCriptRoot\params.json" -value '{
        "root": "c:\\GeoCallLocal",
        "configurationpath": "",
        "credentialName": "",
        "stateAbbreviation": "",
        "stateName": "",
        "storage": {
            "resourcegroup": "prodservices",
            "account": "",
            "configuration": "geocall-deploy-configuration",
            "artifacts": "geocall-config-artifacts"
        },
        "mssql": {
            "server": "localhost",
            "database": "geocall",
            "user": "geocall",
            "password": "geocallpw"
        },
        "postgres": {
            "server": "localhost",
            "database": "geocall",
            "user": "postgres",
            "password": "postgres"
        }
    }'
    
    code "$PSSCriptRoot\params.json"    
    return
}

$cmd = "my" + $Action.replace("-","")

function Report([string]$status, [int]$step, [int]$max, [string]$op) { Write-Progress -Activity "DeployGCLocal: $Action" -Status $status -PercentComplete ($step * 100 / $max) -CurrentOperation $op }

function myInstallGeoCall {
    myResetDatabases

    $maxSteps = 5
    
    #Installing/Importing SimplySql
    Report -Status "Installing/Importing SimplySql & SimplyCredential" -max $maxSteps -step 1
    foreach($m in @("SimplySql","SimplyCredential")) {
        if(Get-Module -ListAvailable -Name $m) { Import-Module $m }
        else {
            Install-Module -Scope CurrentUser -Name $m
            Import-Module -Name $m
        }
    }
    
    #Configuring Az.Accounts
    Report -Status "Configuring Az.Accounts" -max $maxSteps -step 2
    Import-Module Az.Accounts
    Get-AzSubscription -SubscriptionId b90facf8-013b-41f5-bd30-df806dcd0cb2 | Select-AzSubscription | Out-Null
    Set-AzCurrentStorageAccount -ResourceGroupName $config.storage.resourcegroup -Name $config.storage.account | Out-Null 

    #Deploying GCPosh
    Report -Status "Deploying GCPosh" -max $maxSteps -step 3
    if(-not (Test-Path (Join-Path $config.root "GCPosh"))) { New-Item -ItemType Directory -Path (Join-Path $config.root "GCPosh") -Force | Out-Null }
    Get-AzStorageBlobContent -Container $config.storage.configuration -Blob "gcposh.zip" -Destination $config.root -Force | Out-Null
    Expand-Archive -Path (Join-Path $config.root "gcposh.zip") -Force -DestinationPath (Join-Path $config.root "GCPosh")
    Remove-Item (Join-Path $config.root "gcposh.zip")

    #Running Install/Config Logic
    Report -Status "Running Install/Config Logic" -max $maxSteps -step 4
    Import-Module (Join-Path $config.root "gcposh") -Force
    $splat = @{
        RootPath = $config.root
        StateAbbreviation = $config.stateAbbreviation
        StateTitle = $config.StateName
        AzStorageAccount = $config.storage.account
        AzContainerGeoCallConfiguration = $config.storage.artifacts
        AzContainerGeoCallTools = $config.storage.configuration
        SqlServerName = $config.mssql.server
        SqlDatabaseName = $config.mssql.database
        SqlUserName = $config.mssql.user
        SqlPass = $config.mssql.password
        PgServerName = $config.postgres.server
        PgDatabaseName = $config.postgres.database
        PgUserName = $config.postgres.user
        PgPass = $config.postgres.password
        DnsHostName = "localhost"
        UseLocalSSL = $true
        AzToken = Get-AzureToken -ResourceName Storage -AzCredential (Use-Credential $config.credentialName)
    }
    Invoke-GCPDeployment @splat
 
    Report -Status "Installing Local Cert" -max $maxSteps -step 5
    if(-not (Test-Path Cert:\LocalMachine\Root\E5F6EBEDED5AD5BC9706ECB605351B5D55435D0E)) {
        Write-Warning "Adding LocalHost self-signed certificate to trusted root so GeoCall will work over HTTPS locally."
        Import-PfxCertificate -Password (ConvertTo-SecureString -AsPlainText -Force -String password) -CertStoreLocation "Cert:\LocalMachine\Root" -FilePath (Join-Path $config.root "GeoCall\ssl\localhost.pfx")
        Reset-GCPGeoCall
    }    
}

function myDeployConfigLocal {
    
    if(-not (Get-Module GCPosh)) { Import-Module (Join-Path $config.root "GCPosh") }
    $deployPath = Join-Path $config.root "GeoCall\Config\Current"

    Remove-Item -Path $deployPath -Recurse -Force | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $config.root "GeoCall\Config\Current") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $config.root "GeoCall\Config\config-current.txt") | Out-Null
    Get-ChildItem $config.configurationpath | Copy-Item -Destination (Join-Path $config.root "GeoCall\Config\Current") -Recurse

    myApplyParams

    Open-GCPSqlConnection
    Import-GCPUISearch -CN Default -ConfigName Current
    Update-GCPSqlDbCustom -CN Default -ConfigName Current -AllowRollback
    Close-SqlConnection

    Set-GCPDeploymentInfo
    Write-Warning "You will need to run 'Reset-GCPGeocall' to pick up all the changes!"
}

function myApplyParams {
    if(-not (Get-Module GCPosh)) { Import-Module (Join-Path $config.root "GCPosh") }
    Write-Host "Get-GCPVariable | Set-GCPVariable"
    $splat = @{
        StateAbbreviation = $config.stateAbbreviation
        GeoCallPath = (Join-Path $config.root "GeoCall")
        GCDMPath = (Join-Path $config.root "GeoCall\Manager")
        AzureStorageAccount = $config.storage.account
        AzureContainerDeployments = $config.storage.artifacts
        AzureContainerTools = $config.storage.configuration
    }
    Set-GCPVariable @splat -Persist
    
    Write-Host "Set-GCPDeployManager"
    Set-GCPDeployManager -GeoCallRoot (Join-Path $config.root "GeoCall") -BuildType Production

    Write-Host "Set-GCPDeployManager"
    Set-GCPConfigHostJson -ConfigName "Current" -DnsHost "localhost" -PrivateKeyPath (Join-Path $config.root "GeoCall\ssl\cert.key") -PublicCertPath (Join-Path $config.root "GeoCall\ssl\cert.cer")

    Write-Host "Set-GCPConfigMap"
    Set-GCPConfigMap -ConfigName "Current"
    
    Write-Host "Set-GCPConfigWeb"
    Set-GCPConfigWeb -ConfigName "Current" -Title $config.stateName -DnsHost "localhost"
            
    Write-Host "Set-GCPConfigDatabase"
    $splat = @{
        ConfigName = "Current"
        SqlServerName = $config.mssql.Server
        SqlDbName = $config.mssql.Database
        SqlUserName = $config.mssql.User
        SqlUserPass = $config.mssql.Password
        PgServerName = $config.postgres.Server
        PgDbName = $config.postgres.Database
        PgUserName = $config.postgres.User
        PgUserPass = $config.postgres.Password
        SqlTimeZone = "Eastern Standard Time"
    }
    Set-GCPConfigDatabase @splat
}

function myResetDatabases {
    Open-PostGreConnection -Server $config.postgres.server -Database postgres -UserName $config.postgres.user -Password $config.postgres.password
    Invoke-SqlUpdate -Query "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = @db;" -Parameters @{db = $config.postgres.database} | Out-Null
    Invoke-SqlUpdate -Query ("DROP DATABASE IF EXISTS {0}; CREATE DATABASE geocall;" -f $config.postgres.database) | Out-Null

    Set-SqlConnection -Database $config.postgres.database

    foreach($ext in @("postgis","hstore","address_standardizer","address_standardizer_data_us","fuzzystrmatch")) {
        try { Invoke-SqlUpdate -Query "CREATE EXTENSION IF NOT EXISTS $ext;" | Out-Null }
        catch {
            $error.RemoveAt(0)
            (Get-SqlConnection).Open()
            Invoke-SqlUpdate -Query "CREATE EXTENSION IF NOT EXISTS $ext;" | Out-Null
        }
    }

    Close-SqlConnection

    Open-SqlConnection -Server $config.mssql.server
    Invoke-SqlUpdate -Query "DECLARE @ID AS INT, @msg AS varchar(25)
        SET @ID = (SELECT TOP 1 session_id from sys.dm_exec_sessions where database_id = DB_ID(@db))
        
        WHILE @ID IS NOT NULL
        BEGIN
            SET @msg = 'KILL ' + LTRIM(RTRIM(STR(@id)))
            PRINT @msg
            EXECUTE (@msg)
            SET @ID = (SELECT TOP 1 session_id from sys.dm_exec_sessions where database_id = DB_ID(@db))
        END" -Parameters @{db = $config.mssql.database} | Out-Null
    
    Start-Sleep -Milliseconds 250
    Get-SqlMessage

    Invoke-SqlUpdate -Query ("IF EXISTS (SELECT 1 FROM sys.databases WHERE [Name] = '{0}') DROP DATABASE {0}" -f $config.mssql.database) | Out-Null
    Invoke-SqlUpdate -Query ("CREATE DATABASE {0}" -f $config.mssql.database) | Out-Null
    Invoke-SqlUpdate -Query ("ALTER DATABASE {0} SET CONTAINMENT = PARTIAL" -f $config.mssql.database) | Out-Null

    Set-SqlConnection -Database $config.mssql.database

    Invoke-SqlUpdate -Query ("CREATE USER {0} WITH PASSWORD='{1}'; ALTER ROLE db_owner ADD MEMBER {2}" -f $config.mssql.user, $config.mssql.password, $config.mssql.database) | Out-null

    Close-SqlConnection
}

function myUpdateGCPosh {
    #Configuring Az.Accounts
    Write-Host "Configuring Az..."
    Import-Module Az.Accounts
    Get-AzSubscription -SubscriptionId b90facf8-013b-41f5-bd30-df806dcd0cb2 | Select-AzSubscription | Out-Null
    Set-AzCurrentStorageAccount -ResourceGroupName $config.storage.resourcegroup -Name $config.storage.account | Out-Null 

    $gcPoshPath = Join-Path $config.root "GCPosh"
    [version]$oldVersion = "0.0"
    [bool]$isNew = $false

    if(Test-Path $gcPoshPath) {
        Write-Host "Removing old version of GCPosh"
        $oldVersion = Get-Module $gcPoshPath -ListAvailable | Select-Object -ExpandProperty Version
        Get-ChildItem -Path $gcPoshPath -Exclude "variables.json" | Remove-Item -Recurse -Force
    }
    else {
        Write-Host "No GCPosh exists, creating new"
        New-Item -ItemType Directory $gcPoshPath | Out-Null
        $isNew = $true
    }
    
    Write-Host "Deploying GCPosh..."
    Get-AzStorageBlobContent -Container $config.storage.configuration -Blob "gcposh.zip" -Destination $config.root -Force | Out-Null
    Expand-Archive -Path (Join-Path $config.root "gcposh.zip") -Force -DestinationPath (Join-Path $config.root "GCPosh")
    Remove-Item (Join-Path $config.root "gcposh.zip")
    [version]$newVersion = Get-Module $gcPoshPath -ListAvailable | Select-Object -ExpandProperty Version

    if($newVersion -gt $oldVersion) { Write-Host "New version ($newVersion) of GCPosh, replacing the old one ($oldVersion)."}
    else { "Already on the latest version of GCPosh." }

    if($isNew) {
        Import-Module $gcPoshPath -Force
        $splat = @{
            StateAbbreviation = $config.stateAbbreviation
            GeoCallPath = (Join-Path $config.root "GeoCall")
            GCDMPath = (Join-Path $config.root "GeoCall\Manager")
            AzureStorageAccount = $config.storage.account
            AzureContainerDeployments = $config.storage.artifacts
            AzureContainerTools = $config.storage.configuration
        }
        Set-GCPVariable @splat -Persist
        Remove-Module GCPosh
    }
    Import-Module $gcPoshPath -Force -Global
}

function myResetMSSQL {
    if(-not (Get-Module GCPosh)) { Import-Module (Join-Path $config.root "GCPosh") }
    #Stopping GeoCall
    Write-Host "Attempting to stop the GeoCallHostService, cannot continue if this is not successful..."
    Stop-Service GeoCallHostService -Force -ErrorAction Stop

    #Cleaning up the MSSQL Database
    Write-Host "Dropping and Recreating the MSSQL database..."
    Open-SqlConnection -Server $config.mssql.server
    Invoke-SqlUpdate -Query "DECLARE @ID AS INT, @msg AS varchar(25)
        SET @ID = (SELECT TOP 1 session_id from sys.dm_exec_sessions where database_id = DB_ID(@db))
        
        WHILE @ID IS NOT NULL
        BEGIN
            SET @msg = 'KILL ' + LTRIM(RTRIM(STR(@id)))
            PRINT @msg
            EXECUTE (@msg)
            SET @ID = (SELECT TOP 1 session_id from sys.dm_exec_sessions where database_id = DB_ID(@db))
        END" -Parameters @{db = $config.mssql.database} | Out-Null
    
    Start-Sleep -Milliseconds 250
    Get-SqlMessage

    Invoke-SqlUpdate -Query ("IF EXISTS (SELECT 1 FROM sys.databases WHERE [Name] = '{0}') DROP DATABASE {0}" -f $config.mssql.database) | Out-Null
    Invoke-SqlUpdate -Query ("CREATE DATABASE {0}" -f $config.mssql.database) | Out-Null
    Invoke-SqlUpdate -Query ("ALTER DATABASE {0} SET CONTAINMENT = PARTIAL" -f $config.mssql.database) | Out-Null
    Set-SqlConnection -Database $config.mssql.database
    Invoke-SqlUpdate -Query ("CREATE USER {0} WITH PASSWORD='{1}'; ALTER ROLE db_owner ADD MEMBER {2}" -f $config.mssql.user, $config.mssql.password, $config.mssql.database) | Out-null
    
    #Installing GeoCall into the MSSQL database
    Write-Host "Installing GeoCall into the Database (Initialize-GCPSqlDb)..."
    Initialize-GCPSqlDb -ConnectionName Default -TimeZone "Eastern Standard Time"
    
    Write-Host "Applying the default System Settings (Set-GCPSystemSettings)..."
    Set-GCPSystemSettings -ConnectionName Default -DnsHostName "localhost"

    Close-SqlConnection

    # reset admin account:
    Set-GCPAdmin -AdminPW "admin" -ResetPermissions -Verbose

    #Installing Configuration
    Write-Host "Deploying Configuration..."

    myDeployConfigLocal

    Write-Host "Resetting GeoCall (Reset-GCPGeocall)..."
    Reset-GCPGeoCall
    
    Write-Host "Done!"
}
& $cmd