Get-ChildItem -Path "$PSScriptRoot" -filter "*.ps1" | 
    ForEach-Object { . $_.FullName }