Param([parameter(mandatory)][ValidateSet("Dev","Test","UAT","Prod","Other")][string]$EnvType
    , [ValidateLength(3,9)][string]$EnvSuffix
    , [string]$AzureLocation = 'eastus'
    , [string]$TimeZone = [System.TimeZone]::CurrentTimeZone.StandardName
    , [parameter(mandatory)][pscredential]$Credential
    , [string]$VMSecurityGroup = "GeoCallVMs")


    