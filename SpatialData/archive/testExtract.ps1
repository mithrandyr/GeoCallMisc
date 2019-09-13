param([string]$tableName = "gcverbase00001.streets")
$ErrorActionPreference = "stop"
if(-not (test-sqlconnection)) { Open-PostGreConnection -Credential (New-Credential -UserName postgres -Password postgres) -Database geocall }

#Invoke-SqlScalar "select pg_total_relation_size('$tableName')"
$estimate = Invoke-SqlScalar "select pg_table_size('$tableName')"
#Invoke-SqlScalar "SELECT SUM(LENGTH(x::text))/2 AS txtLen FROM $tableName AS x"

try {
    $outputFilePath = "$home\temp\export.raw.dat"
    [System.IO.FileStream]$exportFile = [System.IO.File]::OpenWrite($outputFilePath)
    [Npgsql.NpgsqlRawCopyStream]$pgStream = (Get-SqlConnection).BeginRawBinaryCopy("COPY $tableName TO STDOUT (FORMAT BINARY)")
    
    [System.Diagnostics.Stopwatch]$sw = [System.Diagnostics.Stopwatch]::StartNew()
    <#
    int len;
var data = new byte[10000];
// Export table1 to data array
using (var inStream = conn.BeginRawBinaryCopy("COPY table1 TO STDOUT (FORMAT BINARY)")) {
    // We assume the data will fit in 10000 bytes, in real usage you would read repeatedly, writine to a file.
    len = inStream.Read(data, 0, data.Length);
}
    #>
    [int]$len = 0
    [int]$totalSize = 0
    $data = New-Object -TypeName 'Byte[]' -ArgumentList 8kb
    [int]$accumulator = 0
    [int]$accumulatorSize = $estimate / 50
    while($pgStream.CanRead) {
        $msgCount += 1
        $len = $pgStream.Read($data, 0, $data.Length)
        $exportFile.Write($data, 0, $len)
        $totalSize += $len
        if($len -eq 0) { break }
        if([math]::Truncate($totalSize / $accumulatorSize) -ge $accumulator) {
            $accumulator += 1
            if($totalSize -gt $estimate) { $estimate = $totalSize }
            Write-Progress -Activity "Raw Binary Copy: $tableName" -Status ("{0:#.##}mb out of {1:#.##}mb" -f ($totalSize / 1mb), ($estimate / 1mb)) -PercentComplete ($totalSize * 100 / $estimate)
        }
    }
    Write-Host "Message Count: $msgCount"
    Write-Progress -Activity "Raw Binary Copy: $tableName" -Completed

    $pgStream.Close()
    $sw.Stop()
    Write-Host ("Elapsed Time: {0} seconds" -f $sw.Elapsed.TotalSeconds)
    Write-Host "$totalsize bytes written!"
    Write-Host ("Accuracy: {0}" -f ($estimate / $totalSize).tostring() )
    #Invoke-SqlScalar "SELECT COUNT(1) FROM gcverbase00001.water" -ConnectionName rawtest

}
finally {
    if($pgStream) { $pgStream.Dispose() }
    if($exportFile) { $exportFile.Dispose() }
    $sw = $null
    $data = $null
}