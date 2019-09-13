param([string]$ConnectionName = "default"
    , [System.Management.Automation.Runspaces.PSSession]$RemoteSession
    , [parameter(Mandatory)][string]$ExportObject
    , [string]$OutputFile = ".\export.dat"
    , [int]$BufferSize = 0)

[scriptblock]$cmd = {
    param([string]$outputFilePath, [string]$CN, [string]$object, [int]$buffer)
    try {
        if(Test-Path $outputFilePath) { Remove-Item $outputFilePath }
        [System.IO.FileStream]$exportFile = [System.IO.File]::OpenWrite($outputFilePath)
        [Npgsql.NpgsqlRawCopyStream]$pgStream = (Get-SqlConnection -ConnectionName $CN).BeginRawBinaryCopy("COPY (SELECT * FROM $object) TO STDOUT (FORMAT BINARY)")
        
        [System.Diagnostics.Stopwatch]$sw = [System.Diagnostics.Stopwatch]::StartNew()
        if($buffer -gt 0) { $pgStream.CopyTo($exportFile, $buffer) }
        else { $pgStream.CopyTo($exportFile) }
        $sw.Stop()
        $sw.Elapsed.TotalSeconds
    }
    finally {
        if($pgStream) { $pgStream.Dispose() }
        if($exportFile) { $exportFile.Dispose() }
    }
}

if($RemoteSession) {
    Invoke-Command $RemoteSession -Scriptblock {
        param($cmd, $outFile, $CN, $obj, $bs)
        $rCmd = [scriptblock]::Create($cmd)
        $rCmd.Invoke($outFile, $CN, $obj, $bs)
    } -ArgumentList $cmd, $OutputFile, $ConnectionName, $ExportObject, $BufferSize
}
else {
    & $cmd -OutputFilePath $OutputFile -CN $ConnectionName -object $ExportObject -buffer $BufferSize
}