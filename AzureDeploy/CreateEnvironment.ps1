Param([parameter(mandatory)][ValidateSet("Dev","Test","UAT","Prod","Other")][string]$EnvType
    , [ValidateLength(3,9)][string]$EnvSuffix
    , [string]$AzureLocation = 'eastus'
    , [string]$TimeZone = [System.TimeZone]::CurrentTimeZone.StandardName
    , [parameter(mandatory)][pscredential]$Credential
    , [string]$VMSecurityGroup = "GeoCallVMs"
    , [Parameter(Mandatory)][string]$AzureSubscriptionName
    , [Parameter(Mandatory)][string]$AzureSqlServerName
    , [Parameter(Mandatory)][string]$AzurePgServerName
    , [Parameter(Mandatory)][string]$AzurePrefix
    , [Parameter(Mandatory)][string]$AzureStorageAccountName
    , [Parameter(Mandatory)][string]$BaseDnsHost # geocall.*.*
)

Function TestForResource {
    Param([parameter(mandatory)][hashtable]$resourceHT
        , [parameter(mandatory)][string]$resourceKey
        , [parameter(mandatory)][string]$resourceType
        , [parameter(mandatory)][string]$resourceName
        , [string]$friendlyName
        , [scriptblock]$createSB)

    If(-not $friendlyName) { $friendlyName = $resourceKey }
    $resourceHT.$resourceKey = Get-AzureRmResource -ResourceType $resourceType -Name $resourceName -ErrorAction Ignore
    If($resourceHT.$resourceKey) {
        Write-Host ("{0} already exists for '{1}'!" -f $friendlyName, $resourceHT.$resourceKey.Name)
        $resourceHT.Existing.$friendlyName = $resourceHT.$resourceKey.Name
        If(-not $createSB) { Write-Output $true }
    }
    Else {
        If($createSB) {
            Write-Host ("Creating New {0}: {1}..." -f $friendlyName, $resourceName) -NoNewline
            $resourceHT.$resourceKey = $createSB.Invoke()
            $resourceHT.Created.$friendlyName = $resourceHT.$resourceKey.Name
            Write-Host "Done!"
        }
        Else { Write-Output $false }
    }
}

function ProcessAzCli {
    param([parameter(mandatory)][string[]]$AzCommandList)
    $job = Start-Job { az $using:AzCommandList | ConvertFrom-Json | Write-Output } | Wait-Job
    Receive-job $job
    Remove-Job $job
}

# Setup Variables, etc for script to Run
<#
    Must have module: SimplyCredential, SimplySql and AzureRM (get them from powershellgallery.com)
    also must have Azure CLI version 2.0+ (https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest)
#>

$ErrorActionPreference = "Stop"
Enable-AzureRmAlias
Import-Module SimplySql, SimplyCredential
Import-Module "$PSScriptRoot\..\functions.psm1" -Force
If((Get-AzureRmContext).Subscription.Name -ne $AzureSubscriptionName) { throw "Active subscription is not '$AzureSubscriptionName'; use Set-AzureRmContext to update..." }
Write-Host "Logging into Azure CLI (az)..."
az login -u $Credential.UserName -p $Credential.GetNetworkCredential().Password | Out-Null
Start-Sleep -Seconds 2

If(-not $EnvSuffix) { $EnvSuffix = $EnvType }
$EnvironmentName = "GeoCall$EnvSuffix"
$KeyVaultName = "$AzurePrefix-gc-$EnvSuffix"
$ResourceGroupName = $EnvironmentName #"GeoCall-$EnvSuffix"
$resourceTags = @{Application = "GeoCall"; EnvironmentType = $EnvType; Group = $EnvironmentName}
[string]$localIp = Invoke-RestMethod "https://api.ipify.org?format=json" | Select-Object -ExpandProperty ip

$resources = @{}
$resources.Tags = $resourceTags
$resources.Created = @{}
$resources.Existing = @{}

$Configuration = @{
    Deployment = @{
        Date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
        Computer = $env:COMPUTERNAME
        User = $Credential.UserName
    }
    Environment = @{
        Type = $EnvType
        Suffix = $EnvSuffix
        Name = $EnvironmentName
    }
}

### Creating the Azure Resources needed!
# Resource Group
$resources.ResourceGroupName = Get-AzureRmResourceGroup -Name $ResourceGroupName -ErrorAction Ignore
$Configuration.ResourceGroupName = $ResourceGroupName
If($resources.ResourceGroupName) {
    Write-Host "ResourceGroup already exists: $ResourceGroupName!"
    $resources.Existing.ResourceGroup = $resources.ResourceGroupName.ResourceGroupName
}
Else {
    Write-Host "Creating New Environment: $ResourceGroupName..." -NoNewline
    $resources.ResourceGroup = New-AzureRmResourceGroup -Name $ResourceGroupName -Location $AzureLocation -Tag $resourceTags
    $resources.Created.ResourceGroup = $resources.ResourceGroupName.ResourceGroupName
    Write-Host "Done!"
}

# Create Azure KeyVault
$splat = @{
    ResourceHT = $resources
    ResourceType = "Microsoft.KeyVault/vaults"
    ResourceKey = "KeyVault"
    ResourceName = $KeyVaultName
    CreateSB = [ScriptBlock]{
        $splat = @{
            ResourceGroupName = $ResourceGroupName
            Name = $KeyVaultName
            Location = $AzureLocation
            Tag = $resourceTags
        }
        New-AzureRmKeyVault @splat
    }
}
TestForResource @splat
$Configuration.KeyVaultName = $KeyVaultName

# Create Azure Sql Database
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Sql/servers/databases"
    resourceKey = "SqlDb"
    ResourceName = "$AzureSqlServerName/$EnvironmentName"
    FriendlyName = "SqlDatabase"
    CreateSB = [ScriptBlock]{
            $splat = @{
                ResourceGroupName = "ProdServices"
                ServerName = $AzureSqlServerName
                DatabaseName = $EnvironmentName
                Tags = $resourceTags
                Edition = "Standard"
                MaxSizeBytes = 250gb
                RequestedServiceObjectiveName = "S0"
            }
            New-AzureRmSqlDatabase @splat
        }
}
TestForResource @splat

# Open Firewall Access (Azure SQL and AzurePG)
Write-Host "Adding Firewall Rules (Azure Sql & Azure PG) for '$localIp'..."
Write-Host "  ...SqlServer"
$splat = @{
    ResourceGroupName = "ProdServices"
    ServerName = $AzureSqlServerName
    FirewallRuleName = "{0}-{1:yyyyMMdd}" -f $EnvironmentName, (Get-Date)
    StartIpAddress = $localIp
    EndipAddress = $localIp
}
$sqlFwRule = New-AzureRmSqlServerFirewallRule @splat -ErrorAction Continue

Write-Host "  ...Postgres"
$pgFwRule = ProcessAzCli -AzCommandList @(
        "postgres", "server", "firewall-rule", "create"
        "--resource-group", "prodservices"
        "--server-name", $AzurePgServerName
        "--name"
        "{0}-{1:yyyyMMdd}" -f $EnvironmentName, (Get-Date)
        "--start-ip-address", $localIp
        "--end-ip-address", $localIp
    )

# Configure AzureSql DB App User
Open-SqlConnection -Server $AzureSqlServerName.database.windows.net -Database $EnvironmentName -Credential $Credential -AzureAD

#Create Password
[string]$SqlUserPass = (Get-AzureKeyVaultSecret -VaultName $KeyVaultName -Name "SqlAzure-GeoCallApp").SecretValueText
If([string]::IsNullOrWhiteSpace($SqlUserPass)) {
    $SqlUserPass = GeneratePW
    $splat = @{
        VaultName = $KeyVaultName
        Name = "SqlAzure-GeoCallApp"
        SecretValue = (ConvertTo-SecureString -Force -AsPlainText -String $SqlUserPass)
        Tag = $resourceTags
        ContentType = "password"
    }
    Set-AzureKeyVaultSecret @splat  | Out-Null
}

If(-not (Invoke-SqlScalar -Query "SELECT 1 FROM sys.database_principals WHERE type='s' AND name='GeoCallApp'")) {
    [string]$query= "
        CREATE USER GeoCallApp WITH PASSWORD='$SqlUserPass'
        ALTER ROLE db_owner ADD MEMBER GeoCallApp
    "
    Write-Host "Creating Azure SQL DB App User 'GeoCallApp'..." -NoNewline
    Invoke-SqlUpdate -Query $query | Out-Null
    Write-Host "Done!"
} Else { Write-Host "Azure SQL Db App User 'GeoCallApp' already exists!" }
Close-SqlConnection

$Configuration.Sql = @{
    Server = "$AzureSqlServerName.database.windows.net"
    Database = $EnvironmentName
    User = "GeoCallApp"
    Password = $SqlUserPass
}

# Create Azure PostgreSQL database & user
$pgCred = New-Credential -UserName "dbadmin@$AzurePgServerName" -Password (Get-AzureKeyVaultSecret -VaultName $AzurePrefix -Name "Postgres-$AzurePgServerName-dbadmin").SecretValueText
[string]$gisDB = $EnvironmentName.ToLower()
Open-PostGreConnection -Server $AzurePgServerName.postgres.database.azure.com -Database postgres -Credential $pgCred

#Create Password
[string]$SqlUserPass = (Get-AzureKeyVaultSecret -VaultName $KeyVaultName -Name "PostGres-$gisDB").SecretValueText
If([string]::IsNullOrWhiteSpace($SqlUserPass)) {
    $SqlUserPass = GeneratePW
    $splat = @{
        VaultName = $KeyVaultName
        Name = "PostGres-$gisDB"
        SecretValue = (ConvertTo-SecureString -Force -AsPlainText -String $SqlUserPass)
        Tag = $resourceTags
        ContentType = "password"
    }
    Set-AzureKeyVaultSecret @splat | Out-Null
}

#Create User
If(-not(Invoke-SqlScalar -Query "SELECT 1 FROM pg_roles WHERE rolname=@uName" -Parameters @{uName = $gisDB})){
    [string]$query = "
        CREATE ROLE $gisDB LOGIN PASSWORD '$sqlUserPass';
        GRANT $gisDB TO dbadmin;
        GRANT readonly TO $gisDB;
    "
    Write-Host "Creating Azure Postgres Role (User) '$gisDB'..." -NoNewline
    Invoke-SqlUpdate -Query $query | Out-Null
    Write-Host "Done!"
} Else { Write-Host "Azure Postgres Role (User) '$gisDB' already exists!" }

#Create Database
If(-not(Invoke-SqlScalar -Query "SELECT 1 FROM pg_database WHERE datname=@dbName" -Parameters @{dbName = $gisDB})) {
    [string]$query = "CREATE DATABASE $gisDB OWNER $gisDB;"
    Write-Host "Creating Azure Postgres Database '$gisDB'..." -NoNewline
    Invoke-SqlUpdate -Query $query | Out-Null
    Write-Host "Done!"
}
Else { Write-Host "Azure Postgres Database '$gisDB' already exists!" }

Write-Host "Configuring Extensions..."
Set-SqlConnection -Database $gisDB
ForEach($ext in @("plpgsql","postgis","hstore","address_standardizer","address_standardizer_data_us","fuzzystrmatch")) {
    Write-Host "    +$ext..." -NoNewline
    Try {
        Invoke-SqlUpdate -Query "CREATE EXTENSION IF NOT EXISTS $ext;" | Out-Null
        Write-Host "Done!" -ForegroundColor Green
    } Catch { Write-Host "Error!" -ForegroundColor Red}
}

Close-SqlConnection

$Configuration.Postgres = @{
    Server = "$AzurePgServerName.postgres.database.azure.com"
    Database = $gisDB
    User = "$gisDB@$AzurePgServerName"
    Password = $SqlUserPass
}

# Close Firewall Access (Azure SQL and AzurePG)
Write-Host "Removing Firewall Rules (Azure Sql & Azure PG) for '$localIp'..."
Write-Host "  ...SqlServer ($($sqlFwRule.FirewallRuleName))"
$sqlFwRule | Remove-AzureRmSqlServerFirewallRule | Out-Null

Write-Host "  ...Postgres ($($pgFwRule.name))"
ProcessAzCli -AzCommandList @(
        "postgres", "server", "firewall-rule", "delete"
        "--resource-group", "prodservices"
        "--server-name", $AzurePgServerName
        "--name", $pgFwRule.name
        "--yes"
    )

# VirtualNetwork
[string]$vnetName = "$EnvironmentName-vnet"
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Network/virtualNetworks"
    resourceKey = "VirtualNetwork"
    ResourceName = $vnetName
    CreateSB = [ScriptBlock]{
            $splat = @{
                ResourceGroupName = $ResourceGroupName
                Location = $AzureLocation
                Name = $vnetName
                AddressPrefix = "10.0.0.0/24"
                Subnet = (New-AzureRmVirtualNetworkSubnetConfig -Name "default" -AddressPrefix "10.0.0.0/24" -ServiceEndpoint "Microsoft.Sql")
                Tag = $resourceTags
            }
            New-AzureRmVirtualNetwork @splat -Force -WarningAction SilentlyContinue
        }
}
TestForResource @splat
$Configuration.VNet = $vnetName

$VirtualNetworkRuleName = "{0}VNet" -f $EnvironmentName
# Adding VirtualNetworks to Azure SQL
if(Get-AzureRmSqlServerVirtualNetworkRule -ResourceGroupName "ProdServices" -ServerName $AzureSqlServerName | Where-Object VirtualNetworkRuleName -eq $VirtualNetworkRuleName) {
    Write-Host "VNetRuleAzureSql already exists for '$AzurePrefix-$VirtualNetworkRuleName'!"
    $resources.Existing.VNetRuleAzureSql = "$AzurePrefix-$VirtualNetworkRuleName"
}
else {
    $splat = @{
        ResourceGroupName = "ProdServices"
        ServerName = $AzureSqlServerName
        VirtualNetworkRuleName = $VirtualNetworkRuleName
        VirtualNetworkSubnetId = "{0}/subnets/default" -f $resources.VirtualNetwork.Id
    }
    Write-Host ("Creating New {0}: {1}..." -f "VNetRuleAzureSql", "$AzurePrefix-$VirtualNetworkRuleName") -NoNewline
    New-AzureRmSqlServerVirtualNetworkRule @splat | Out-Null
    $resources.Created.VNetRuleAzureSql = "$AzurePrefix-$VirtualNetworkRuleName"
    Write-Host "Done!"
}

# Adding VirtualNetworks to Azure Postgres
if(ProcessAzCli -AzCommandList "postgres","server","vnet-rule","list","--resource-group","prodservices","--server-name",$AzurePgServerName | Where-Object name -eq $VirtualNetworkRuleName) {
    Write-Host "VNetRuleAzurePostgres already exists for '$AzurePgServerName-$VirtualNetworkRuleName'!"
    $resources.Existing.VNetRuleAzurePostgres = "$AzurePgServerName-$VirtualNetworkRuleName"
}
else {
    Write-Host ("Creating New {0}: {1}..." -f "VNetRuleAzurePostgres", "$AzurePgServerName-$VirtualNetworkRuleName") -NoNewline
    [string[]]$azCommandList = @(
        "postgres","server","vnet-rule","create"
        "--name", $VirtualNetworkRuleName
        "--resource-group", "ProdServices"
        "--server-name", "$AzurePgServerName"
        "--subnet", ("{0}/subnets/default" -f $resources.VirtualNetwork.Id)
    )
    ProcessAzCli -AzCommandList $azCommandList | Out-Null
    $resources.Created.VNetRuleAzurePostgres = "$AzurePgServerName-$VirtualNetworkRuleName"
    Write-Host "Done!"
}


# NetworkSecurityGroup
[string]$nsgName = "$EnvironmentName-nsg"
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Network/networkSecurityGroups"
    resourceKey = "NetworkSecurityGroup"
    ResourceName = $nsgName
    CreateSB = [ScriptBlock]{
            $splat = @{
                ResourceGroupName = $ResourceGroupName
                Location = $AzureLocation
                Name = $nsgName
                Tag = $resourceTags
            }
            New-AzureRmNetworkSecurityGroup @splat -Force -WarningAction SilentlyContinue
        }
}
TestForResource @splat
$Configuration.NSG = $nsgName

# NetworkSecurityGroupRules
$RulesToAdd = @(
    @{Name="AllowRDP"; Port=3389; Priority = 1000}
    @{Name="AllowSSL"; Port=443; Priority = 1010}
    @{Name="AllowWinRmSSL"; Port=5986; Priority = 1020}
)

ForEach($rta in $RulesToAdd) {
    $nsg = Get-AzureRmNetworkSecurityGroup -Name $resources.NetworkSecurityGroup.Name -ResourceGroupName $resources.NetworkSecurityGroup.ResourceGroupName
    $nsgRules = Get-AzureRmNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg
    $rList = @($nsgRules | Where-Object { $_.DestinationPortRange -eq $rta.Port -and $_.Protocol -eq "TCP" -and $_.Direction -eq "Inbound"})
    If($rList.count -gt 1) { Write-Host ("Multiple Network Security Rules for Port {0} (Names: {1})!" -f $rta.Port, $rlist.Name -join ", ") }
    ElseIf($rList.count -eq 1) { Write-Host ("Network Security Rule for Port {0} already exists$(If($rlist[0].Name -ne $rta.Name){' (Name = {1})'})!" -f $rta.Port, $rList[0].Name)}
    Else {
        Write-Host ("Creating Network Security Rule '{0}'..." -f $rta.Name) -NoNewline
        $splat = @{
            Protocol = "TCP"
            Direction = "Inbound"
            Priority = $rta.Priority
            SourceAddressPrefix = "*"
            SourcePortRange = "*"
            DestinationAddressPrefix = "*"
            Access = "Allow"
            Name = $rta.Name
            DestinationPortRange = $rta.Port
        }
        Add-AzureRmNetworkSecurityRuleConfig @splat -NetworkSecurityGroup $nsg | Set-AzureRmNetworkSecurityGroup | Out-Null
        Write-Host "Done!"
    }

}

[string]$vmName = "gc-{0}-01" -f $EnvSuffix
# PublicIpAddress
[string]$publicIpName = "$vmName-PublicIp"
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Network/publicIPAddresses"
    resourceKey = "PublicIpAddress"
    ResourceName = $publicIpName
    CreateSB = [ScriptBlock]{
            $splat = @{
                ResourceGroupName = $ResourceGroupName
                Location = $AzureLocation
                Name = $publicIpName
                AllocationMethod = "Dynamic"
                DomainNameLabel = "$AzurePrefix-$vmname".ToLower()
                Tag = $resourceTags
            }
            New-AzureRmPublicIpAddress @splat -Force -WarningAction SilentlyContinue
        }
}
TestForResource @splat
$Configuration.PublicIp = @{
    Name = $publicIpName
    DnsName = (Get-AzureRmPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $publicIpName).DnsSettings.Fqdn
}

#Create DNS Record
$record = Get-AzureRmDnsRecordSet -ResourceGroupName "ProdServices" -ZoneName $BaseDnsHost -Name $EnvSuffix -RecordType CNAME -ErrorAction Ignore
If($record) {
    If($record.Records[0].Cname -eq $Configuration.PublicIp.DnsName) {
        Write-Host "DNS Record for '$EnvSuffix.$BaseDnsHost' already exists!"
    }
    Else {
        Write-Host "DNS Record for '$EnvSuffix.$BaseDnsHost' has wrong data..." -NoNewline
        $record.Records.Clear()
        $record.Records.Add((New-AzureRmDnsRecordConfig -Cname $Configuration.PublicIp.DnsName))
        $record | Set-AzureRmDnsRecordSet | Out-Null
        Write-Host "Updated!"
    }
}
Else {
    Write-Host "Creating DNS record for '$EnvSuffix.$BaseDnsHost' ..." -NoNewline
    $splat = @{
        ResourceGroupName = "ProdServices"
        ZoneName = $BaseDnsHost
        Name = $EnvSuffix
        RecordType = "CNAME"
        ttl = 3600
        DnsRecords = New-AzureRmDnsRecordConfig -Cname $Configuration.PublicIp.DnsName
    }
    New-AzureRmDnsRecordSet @splat | Out-Null
    Write-Host "Done!"
}
$Configuration.DnsName = "$EnvSuffix.$BaseDnsHost"

# Create Network Interface
[string]$nicName = "$vmName-nic"
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Network/networkInterfaces"
    resourceKey = "NetworkInterface"
    ResourceName = $nicName
    CreateSB = [ScriptBlock]{
            $splat = @{
                Name = $nicName
                ResourceGroupName = $ResourceGroupName
                Location = $AzureLocation
                SubnetId = $resources.VirtualNetwork | Get-AzureRmVirtualNetwork | Get-AzureRmVirtualNetworkSubnetConfig -Name "default" | Select-Object -ExpandProperty Id
                PublicIpAddressId = $resources.PublicIpAddress.Id
                NetworkSecurityGroupId = $resources.NetworkSecurityGroup.Id
                Tag = $resourceTags
            }
            New-AzureRmNetworkInterface @splat -Force -WarningAction Ignore
        }
}
TestForResource @splat

# VirtualMachine
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Compute/virtualMachines"
    resourceKey = "VirtualMachine"
    ResourceName = $vmName
    CreateSB = [ScriptBlock]{
            $resources.VMCredential = New-Credential -UserName sadmin -Password (GeneratePW)
            $splat = @{
                VaultName = $KeyVaultName
                Name = "VM-$vmName-sadmin"
                SecretValue = $resources.VMCredential.Password
                Tag = $resourceTags
                ContentType = "password"
            }
            Set-AzureKeyVaultSecret @splat | Out-Null
            New-AzureRmVMConfig -VMName $vmName -VMSize "Standard_B2s" -AssignIdentity |
                Set-AzureRmVMOperatingSystem -Windows -ComputerName $vmName -Credential $resources.VMCredential -TimeZone $TimeZone |
                Set-AzureRmVMSourceImage -PublisherName "MicrosoftWindowsServer" -Offer WindowsServer -Skus "2016-Datacenter-Server-Core-smalldisk" -Version Latest |
                Add-AzureRmVMNetworkInterface -Id $resources.NetworkInterface.Id |
                Set-AzureRmVMBootDiagnostics -Enable -StorageAccountName $AzureStorageAccountName -ResourceGroupName "ProdServices" |
                New-AzureRmVM -ResourceGroupName $ResourceGroupName -Location $AzureLocation -Tag $resourceTags
        }
}
TestForResource @splat
$Configuration.VM = @{
    Name = $vmName
    User = "sadmin"
    Password = (Get-AzureKeyVaultSecret -VaultName $KeyVaultName -Name "VM-$vmName-sadmin").SecretValueText
}

# Add VM to GeoCallVMs group
Write-Host "Adding the VM identity to the Security Group '$VMSecurityGroup'..."
try {
    Connect-AzureAD -Credential $Credential | Out-Null
    $g = Get-AzureADGroup -Filter "DisplayName eq '$VMSecurityGroup'"
    if($g) {
        $vmId = Get-AzureRMVM -ResourceGroupName $ResourceGroupName -Name $vmName | Select-Object -ExpandProperty Identity | Select-Object -ExpandProperty PrincipalId
        Add-AzureAdGroupMember -ObjectId $g.ObjectId -RefObjectId $vmId
    }
    else { Write-Warning "Security Group '$VMSecurityGroup' does not exist!" }
}
catch { Write-Warning "Failed to add the '$vmName' (VM) to '$VMSecurityGroup' (securitygroup): $_" }

# VirtualMachine DataDisk
[string]$vmDiskName = "$vmName-data"
$splat = @{
    resourceHT = $resources
    ResourceType = "Microsoft.Compute/disks"
    ResourceKey = "VirtualMachineDataDisk"
    ResourceName = $vmDiskName
    FriendlyName = "VirtualMachine DataDisk"
    CreateSB = [scriptblock]{
            Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vmName |
                Add-AzureRmVMDataDisk -Name $vmDiskName -CreateOption "Attach" -Lun 0 -ManagedDiskId (
                        New-AzureRmDiskConfig -SkuName "Premium_LRS" -Location $AzureLocation -CreateOption Empty -DiskSizeGB 32 -Tag $resourceTags |
                        New-AzureRmDisk -DiskName $vmDiskName -ResourceGroupName $ResourceGroupName
                    ).Id |
                Update-AzureRmVM |
                Out-Null
        }
}
TestForResource @splat

# Restart VM after applying security group change.

#Enable RemotePowershell
$splatRps = @{
    ComputerName = $Configuration.DnsName
    Credential = New-Credential -UserName $Configuration.VM.User -Password $Configuration.VM.Password
    SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck
    UseSSL = $true
    ErrorAction = "Stop"
}
try {
    Invoke-Command @splatRps -ScriptBlock { Write-Host "PowerShell Remoting is active on $Env:ComputerName!" }
} catch {
    Write-Host "Enable PowerShell Remoting on '$vmName'..." -NoNewline
    Invoke-AzureRmVMRunCommand -ResourceGroupName $ResourceGroupName -Name $vmName -CommandId EnableRemotePS | Out-Null

    Invoke-Command @splatRps -ScriptBlock { }
    Write-Host "Done!"
}

#Update PowerShell Configuration & Trust PSGallery
Invoke-Command @splatRps -ScriptBlock {
    Write-Host "Installing NuGet PackageProvider..."
    Install-PackageProvider -Name NuGet -Force | Out-Null

    if((Get-PSRepository -Name PSGallery).InstallationPolicy -ne "Trusted") {
        Write-Host "Setting PSGallery as trusted..."
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    else { Write-Host "PSGallery is already trusted." }
}

# Install PackageManagement & PowerShellGet
Invoke-Command @splatRps -ScriptBlock {
    Write-Host "Updating PackageManagement..."
    Install-Module PackageManagement -Force -SkipPublisherCheck -ErrorAction Stop
}

Invoke-Command @splatRps -ScriptBlock {
    Write-Host "Updating PowerShellGet..."
    Install-Module PowerShellGet -Force -SkipPublisherCheck -ErrorAction Stop
}

#Install SimplySql, SimplyCredential
Invoke-Command @splatRps -ScriptBlock {
    Write-Host "Installing SimplySql..."
    Import-Module PowerShellGet -Force
    Install-Module SimplySql
    
    Write-Host "Installing SimplyCredential..."
    Install-Module SimplyCredential
}

#Initalize and Format DataDisk for GeoCall
$remoteSession = New-AzurePSSession -ComputerName $Configuration.DnsName -Credential (New-Credential -UserName $Configuration.VM.User -Password $Configuration.VM.Password)
Invoke-Command -Session $remoteSession -ScriptBlock {
    if(Get-Volume -DriveLetter "G" -ErrorAction Ignore) { Write-Host "DataDisk already initalized and formatted to Drive G." }
    else {
        Write-Host "Initalizing, Formatting DataDisk to Drive G..." -NoNewline
        Get-Disk |
            Where-Object PartitionStyle -eq "raw" |
            Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -UseMaximumSize -DriveLetter "G" |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel "GeoCall" -Force -Confirm:$false |
            Out-Null
        Write-Host "Done!"
    }
}
$Configuration.VM.DriveLetter = "G"

#Update Firewall Settings
Invoke-Command -Session $remoteSession -ScriptBlock {
    $OpenPorts = Get-NetFirewallRule -Enabled true -Direction Inbound |
        Where-Object { $_.profile -like "*Public*" -or $_.profile -like "*any"} |
        Get-NetFirewallPortFilter |
        Select-Object -ExpandProperty localport -Unique

    $Using:RulesToAdd.Port |
        ForEach-Object {
            if($_ -notin $OpenPorts) {
                $splat = @{
                    Name = "GeoCall-Configuration-Port-$_"
                    DisplayName = "GeoCall-Configuration-Port-$_"
                    Description = "GeoCall Configuration for Port $_"
                    Enabled = "True"
                    Profile = "Public"
                    Direction = "Inbound"
                    Action = "Allow"
                    Protocol = "TCP"
                    LocalPort = $_
                }
                New-NetFirewallRule @splat | Out-Null
                Write-Host "Allowed Port $_ (inbound) on Windows Firewall Public Profile"
            } else { Write-Host "Port $_ (inbound) already allowed in Windows Firewall."}
        }
}

Remove-PSSession $remoteSession

#Save Configuration
[string]$azStorageContainer = "geocall-deploy-configuration"
Write-Host "Saving configuration to '$azStorageContainer'..." -NoNewline
$Configuration | ConvertTo-Json -Depth 5 | Set-Content -Path "$EnvironmentName.json" -Force
Set-AzureRmCurrentStorageAccount -ResourceGroupName "ProdServices" -Name $AzureStorageAccountName | Out-Null
Set-AzureStorageBlobContent -Container $azStorageContainer -File "$EnvironmentName.json".ToLower() -BlobType Block -Force | Out-Null
Remove-Item -Path "$EnvironmentName.json"
Write-Host "Done!"


<#
    TODO LIST
    
    max length of azure keyvault name = 127 characters
#>

$resources | Export-Clixml -Depth 10 -Path ("$EnvironmentName-Deploy-{0:yyyyMMdd-HHmm}.clixml" -f (Get-Date))