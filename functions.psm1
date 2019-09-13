Function ProcessPG ([parameter(ValueFromPipeline)][string]$Data) {
    Begin { [string]$result = $null }
    Process {
        If(-not [string]::IsNullOrWhiteSpace($data)) {
            $data = $data.Trim()
            If($data.StartsWith(";")) {
                Write-Output ($result + ";")
                $result = $data.Substring(1)
            }
            Else {
                If([string]::IsNullOrWhiteSpace($result)) { $result = $data }
                Else { $result+= [environment]::NewLine + $data }

                If($result.EndsWith(";")) {
                    Write-Output $result
                    $result = ""
                }
            }
        }
    }
    End { If(-not [string]::IsNullOrWhiteSpace($result)) { Write-Output ($result + ";") } }
}

Function ShortenString ([parameter(ValueFromPipeline)][string]$Data, [ValidateRange(1,200)][int]$length = 50) {
    If([string]::IsNullOrWhiteSpace($data)) { Write-Output ([string]::Empty) }
    Else {
        $data = $data.Replace([environment]::NewLine," ")
        If($data.Length -gt $length) { Write-Output $data.Substring(0, $length) }
        Else { Write-Output $data }
    }
}

Function GeneratePW { New-Password -Length 24 -ExcludeCharacters ("<>'\%;&" + '`"')| Write-Output }

Function Enter-AzureVMPowerShell {
    Param([parameter(mandatory)][string]$dnsName
        , [parameter(mandatory)][pscredential]$Credential)

    Enter-PSSession -ComputerName $dnsName -Credential $Credential -UseSSL -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck)
}

Export-ModuleMember -Function ProcessPG, ShortenString, GeneratePW