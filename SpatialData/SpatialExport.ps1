[cmdletBinding(DefaultParameterSetName="default")]
param(
    [Parameter()][Alias("cn")][string]$ConnectionName = "default"
    , [Parameter(ParameterSetName="default")][ValidateSet("Base","ServiceArea")][string]$Type = "Base"
    , [Parameter(Mandatory, ParameterSetName="custom")][string[]]$TableList
    , [Parameter()][string]$ArchivePath
)

$ErrorActionPreference = "Stop"

if(-not (Test-SqlConnection -ConnectionName $ConnectionName)) { throw "Not a valid SqlConnection '$ConnectionString'." }
if($Type -eq "Base") {
    $TableList = @("gcdefault.dbversion"
    "gcdefault.mapnote"
    "gcdefault.mapnotecategory"
    "gcdefault.version"
    "gcdefault.versionhistory"
    "gcverbase00001.county"
    "gcverbase00001.places"
    "gcverbase00001.railroads"
    "gcverbase00001.streets"
    "gcverbase00001.surfacewater"
    "gcverbase00001.water"
    "gcverbase00001.parcel")
}
elseif($Type -eq "ServiceArea") { $TableList = @("gcversa00001.servicearea") }
else { $Type = "Custom" }

if(-not $ArchivePath) { $ArchivePath = ".\$Type.zip" }

#setup working area
$workingFolder = [System.IO.Path]::GetTempFileName()
Remove-Item -Path $workingFolder
New-Item -Path $workingFolder -ItemType Directory | Out-Null

[System.Diagnostics.Stopwatch]$sw = [System.Diagnostics.Stopwatch]::StartNew()
#process tables to export
$c = 0
$UncompressedTotal = 0
foreach($t in $TableList) {   
    $c += 1 
    $sw.Restart()
    Write-Progress -Activity SpatialExport -Status "Processing $t..." -PercentComplete ($c * 50 / $TableList.count)
    Write-Verbose "Table: $t"

    [int]$estimate = Invoke-SqlScalar "SELECT pg_table_size('$t')" -ConnectionName $ConnectionName
    [int]$totalSize = 0
    [int]$accumulator = 0
    [int]$accumulatorSize = $estimate / 50
    if($accumulatorSize -lt 2.5mb) { $accumulatorSize = 2.5mb }
    try {
        [Npgsql.NpgsqlRawCopyStream]$rcs = (Get-SqlConnection -ConnectionName $ConnectionName).BeginRawBinaryCopy("COPY (SELECT * FROM $t) TO STDOUT (FORMAT BINARY)")
        [System.IO.FileStream]$file = [System.IO.File]::OpenWrite((Join-Path $workingFolder "$t.dat"))
        $data = New-Object -TypeName 'Byte[]' -ArgumentList 8kb

        while($rcs.CanRead) {
            $len = $rcs.Read($data, 0, $data.Length)
            $file.Write($data, 0, $len)
            $totalSize += $len
            if($len -eq 0) { break }
            if([math]::Truncate($totalSize / $accumulatorSize) -ge $accumulator) {
                $accumulator += 1
                if($totalSize -gt $estimate) { $estimate = $totalSize }
                Write-Progress -Activity "Raw Binary Copy" -Status ("{0:#.##}MB out of {1:#.##}MB" -f ($totalSize / 1mb), ($estimate / 1mb)) -PercentComplete ($totalSize * 100 / $estimate) -ParentId 0 -Id 1
            }
        }
    }
    catch {
        if($rcs) { $rcs.Close() }
        if($file) { $file.Close() }
        throw $_
    }
    Write-Progress -Activity "RawBinaryCopy" -ParentId 0 -Completed -Id 1
    $UncompressedTotal += $totalSize
    $rcs.Close()
    $file.Close()
    $sw.Stop()
    Write-Verbose ("Processed {0:#.##}MB in {1}s for an average speed of {2:#.##}mb/s" -f ($totalSize/1mb), $sw.Elapsed.TotalSeconds, (($totalSize / 1mb) / $sw.Elapsed.TotalSeconds))
}
Write-Progress -Activity SpatialExport -Completed
try {
    $sw.Start()
    Write-Verbose "Compressing archive '$ArchivePath'"
    Get-ChildItem -Path $workingFolder -File | Compress-Archive -DestinationPath $ArchivePath -Update
    $sw.Stop()
    Write-Verbose ("Archived {0:#.##}MB into {1:#.##}MB in {2} seconds." -f ($UncompressedTotal / 1mb), ((Get-Item -Path $ArchivePath).Length / 1mb), $sw.Elapsed.TotalSeconds)
    Remove-Item -Path $workingFolder -Recurse -Force
}
catch {
    if(Test-Path $workingFolder) { Remove-Item -Path $workingFolder -Force -Recurse }
    throw $_
}