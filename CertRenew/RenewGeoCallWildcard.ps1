param([switch]$Production
    , [Parameter(Mandatory)]$baseDnsHost
    , [Parameter(Mandatory)]$AzureResourceGroup  #"prodservices"
    , [Parameter(Mandatory)]$AzureStorageName
    , [Parameter(Mandatory)]$FriendlyName
)
Import-Module Posh-ACME
$ErrorActionPreference = "Stop"
$AccountContacts = @() #email addresses to get notified on nearing expiration

if($Production) { Set-PAServer LE_Prod }
else { Set-PAServer LE_Stage }

if(-not (Get-PAAccount)) {
    Write-Host "Building account..."
    New-PAAccount -Contact @AccountContacts -AcceptTOS
}

Write-Host "Building order..."
New-PAOrder -Domain "*.$baseDnsHost" -Force -FriendlyName $FriendlyName | Out-Null

Write-Host "Getting auth..."
$authNeeded = (Get-PAOrder | Get-PAAuthorizations)[0]

#Get TxtRecord
$txtValue = Get-KeyAuthorization -Token $authNeeded[0].DNS01Token -ForDNS

#ADD DNS
Write-Host "Adding dns..."
$record = Get-AzDnsRecordSet -ResourceGroupName $AzureResourceGroup -ZoneName $baseDnsHost -Name "_acme-challenge" -RecordType TXT -ErrorAction Ignore
if($record) {
    $record.Records.Clear()
    $record.Records.Add((New-AzDnsRecordConfig -Value $txtValue))
    $record | Set-AzDnsRecordSet | Out-Null
}
else {
    $splat = @{
        ResourceGroupName = $AzureResourceGroup
        ZoneName = $baseDnsHost
        Name = "_acme-challenge"
        RecordType = "TXT"
        ttl = 10
        DnsRecords = New-AzDnsRecordConfig -Value $txtValue
    }
    New-AzDnsRecordSet @splat | Out-Null
}
Start-Timer -Time 30 -NoAlarm

#Verify auth
Write-Host "Verifying auth..."
Write-Host "Sending Challenge..."
$authNeeded.DNS01Url | Send-ChallengeAck 

Write-Host "Checking Challenge..."
$start = (Get-Date)
while((Get-Date) -lt $start.AddSeconds(15)) {
    Start-Sleep -Milliseconds 500
    Write-Host "getting authorization!"
    $authStatus = Get-PAOrder | Get-PAAuthorizations | Select-Object -ExpandProperty status
    if($authStatus -ne "pending") { break }
}
if($authStatus -ne "valid") { throw "not validated!" }

#remove TXT record
Write-Host "Removing dns..."
$record = Get-AzDnsRecordSet -ResourceGroupName $AzureResourceGroup -ZoneName $baseDnsHost -Name "_acme-challenge" -RecordType TXT -ErrorAction Ignore
$record | Remove-AzDnsRecordSet

Write-Host "Refreshing Order..."
Get-PAOrder -Refresh | Out-Null

#Cert
Write-Host "Getting certificate..."
$certInfo = New-PACertificate "*.$baseDnsHost"

#Building ssl.zip
Write-Host "Building archive..."
$path = [System.IO.Path]::GetTempFileName()
$sslPath = Join-Path $path "ssl"
$sslArchivePath = Join-Path $path "ssl.zip"

Remove-Item $path
New-Item -ItemType Directory -Path $path -Force | Out-Null
New-Item -ItemType Directory -Path $sslPath -Force | Out-Null

Copy-Item -Destination $sslPath -Path $certInfo.CertFile
Copy-Item -Destination $sslPath -Path $certInfo.KeyFile
Copy-Item -Destination $sslPath -Path $certInfo.ChainFile

Compress-Archive -DestinationPath $sslArchivePath -Path $sslPath | Out-Null
Remove-Item $sslPath -Recurse -Force

if($Production) {
    Write-Host "Uploading archive to Azure Storage..."
    Set-AzCurrentStorageAccount -ResourceGroupName $AzureResourceGroup -Name $AzureStorageName | Out-Null
    Set-AzStorageBlobContent -Container "geocall-deploy-configuration" -File $sslArchivePath -BlobType Block -Force | Out-Null
    Remove-Item $sslArchivePath -Force
    Remove-Item $path -Recurse -Force
}
else { $sslArchivePath }