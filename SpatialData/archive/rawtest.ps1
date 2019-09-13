param([int]$bufferSize = 0, [switch]$doExport, [switch]$doImport)
[string]$outputFilePath = "$home\temp\postgres-export.dat"

#exporting data
if($doExport){
    try {
        if(Test-Path $outputFilePath) { Remove-Item $outputFilePath }
        Open-PostGreConnection -Server georgia811.postgres.database.azure.com -Database gisdata -Credential (Use-Credential pgGeoCallDev) -ConnectionName rawTest
        [System.IO.FileStream]$exportFile = [System.IO.File]::OpenWrite($outputFilePath)
        [Npgsql.NpgsqlRawCopyStream]$pgStream = (Get-SqlConnection -ConnectionName rawTest).BeginRawBinaryCopy("COPY gcversa00001.parcels TO STDOUT (FORMAT BINARY)")
        
        [System.Diagnostics.Stopwatch]$sw = [System.Diagnostics.Stopwatch]::StartNew()
        if($bufferSize -gt 0) { $pgStream.CopyTo($exportFile, $bufferSize) }
        else { $pgStream.CopyTo($exportFile) }
        $sw.Stop()
        Write-Host ("Elapsed Time: {0} seconds" -f $sw.Elapsed.TotalSeconds)
    }
    finally {
        if($pgStream) { $pgStream.Dispose() }
        if($exportFile) { $exportFile.Dispose() }
        $sw = $null
        if(Test-SqlConnection -ConnectionName rawTest) { Close-SqlConnection -ConnectionName rawTest }
    }
}

#importing data
if($doImport) {
    try {
        Open-PostGreConnection -Credential (New-Credential -UserName postgres -Password postgres) -Database test -ConnectionName rawTest
        Invoke-SqlUpdate -ConnectionName rawtest -Query "TRUNCATE TABLE gcversa00001.servicearea"
        [System.IO.FileStream]$exportFile = [System.IO.File]::OpenRead($outputFilePath)
        [Npgsql.NpgsqlRawCopyStream]$pgStream = (Get-SqlConnection -ConnectionName rawTest).BeginRawBinaryCopy("COPY gcversa00001.parcels FROM STDIN (FORMAT BINARY)")
        
        [System.Diagnostics.Stopwatch]$sw = [System.Diagnostics.Stopwatch]::StartNew()
        if($bufferSize -gt 0) { $exportFile.CopyTo($pgStream, $bufferSize) }
        else { $exportFile.CopyTo($pgStream) }
        $pgStream.Close()
        $sw.Stop()
        Write-Host ("Elapsed Time: {0} seconds" -f $sw.Elapsed.TotalSeconds)
        Invoke-SqlScalar "SELECT COUNT(1) FROM gcversa00001.servicearea" -ConnectionName rawtest
    }
    finally {
        if($pgStream) { $pgStream.Dispose() }
        if($exportFile) { $exportFile.Dispose() }
        $sw = $null
        if(Test-SqlConnection -ConnectionName rawTest) { Close-SqlConnection -ConnectionName rawTest }
    }
}