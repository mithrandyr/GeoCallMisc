param(
    [Parameter(Mandatory)][string]$EnvSuffix
    , [Parameter(Mandatory)][pscredential]$pgCred
    , [string]$VmSecurityGroup = "GeoCallVMs"
    , [string]$pgServer
    , [string]$sqlServer
    , [string]$baseDnsHost #geocall.*.*
)

[string]$rgName = "GeoCall$EnvSuffix"
[string]$envName = "geocall$EnvSuffix".ToLower()

Write-Host "Remove VM from Security Group..."
$groupId = Get-AzureADGroup -SearchString $VmSecurityGroup | Select-Object -ExpandProperty ObjectId
Get-AzureRmVM -ResourceGroupName $rgName -ErrorAction Ignore | 
    ForEach-Object {
        Remove-AzureADGroupMember -ObjectId $groupId -MemberId $_.Identity.PrincipalId -ErrorAction Ignore
    }

Write-Host "Stopping VM..."
Get-AzureRmVM -ResourceGroupName $rgName -ErrorAction Ignore | 
    ForEach-Object {
        Stop-AzureRmVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name -Force | Out-Null
    }

Write-Host "Check for ResourceGroup: $rgName & starting delete job if it exists."
$job = Remove-AzureRmResourceGroup -Name $rgName -Force -AsJob -ErrorAction Ignore

$sqlDb = Get-AzureRmSqlDatabase -ResourceGroupName ProdServices -ServerName $sqlServer -DatabaseName $envName -ErrorAction Ignore
if($sqlDb) {
    Write-Host "Removing Azure SqlDB: $envName..." -NoNewline
    $sqlDb | Remove-AzureRmSqlDatabase -Force | Out-Null
    Write-Host "Done!"
}

$dns = Get-AzureRmDnsRecordSet -ResourceGroupName prodservices -Name $EnvSuffix -ZoneName $baseDnsHost -RecordType CNAME -ErrorAction Ignore
if($dns) {
    Write-Host "Removing Azure DNS: $EnvSuffix.$baseDnsHost..." -NoNewline
    $dns | Remove-AzureRmDnsRecordSet
    Write-Host "Done!"
}

[string]$localIp = Invoke-RestMethod "https://api.ipify.org?format=json" | Select-Object -ExpandProperty ip
Write-Host "Postgres FireWall for IP $localIp"
[string[]]$argList = @(
    "postgres", "server", "firewall-rule", "create"
    "--resource-group", "prodservices"
    "--server-name", ($pgServer.Split(".")[0])
    "--name"
    "{0}-{1:yyyyMMdd}" -f $envName, (Get-Date)
    "--start-ip-address", $localIp
    "--end-ip-address", $localIp
)
$pgFwRule = az $argList | ConvertFrom-Json

Open-PostGreConnection -Server $pgServer -Database postgres -Credential $pgCred
if(Invoke-SqlScalar -Query "SELECT 1 FROM pg_database WHERE datname = @n" -Parameters @{n=$envName}) {
    Write-Host "Removing Azure Postgres Database..." -NoNewline
    Invoke-SqlUpdate -Query "DROP DATABASE $envName" | Out-Null
    Write-Host "Done!"
}

if(Invoke-SqlScalar -Query "SELECT 1 FROM pg_roles WHERE rolname = @n" -Parameters @{n=$envName}) {
    Write-Host "Removing Azure Postgres Role..." -NoNewline
    Invoke-SqlUpdate -Query "DROP ROLE $envName" | Out-Null
    Write-Host "Done!"
}
Close-SqlConnection

Write-Host "  ...Postgres ($($pgFwRule.name))"
[string[]]$argList = @(
    "postgres", "server", "firewall-rule", "delete"
    "--resource-group", "prodservices"
    "--server-name", ($pgServer.Split(".")[0])
    "--name", $pgFwRule.name
    "--yes"
)
az $argList


Write-Host "Waiting for ResourceGroup deletion to finish..." -NoNewline
while($job -and ($job.State -eq "Running")) {
    Write-Host "..." -NoNewline
    Start-Sleep -Seconds 5
}
Write-Host "Done!"