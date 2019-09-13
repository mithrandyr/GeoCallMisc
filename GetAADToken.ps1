# - add list of valid resourceAppIdURIs....
# https://docs.microsoft.com/en-us/azure/active-directory/managed-service-identity/services-support-msi
# https://blogs.technet.microsoft.com/stefan_stranger/2018/06/06/connect-to-azure-sql-database-by-obtaining-a-token-from-azure-active-directory-aad/

[CmdletBinding()]
[OutputType([string])]
Param (
    [Parameter(Mandatory, Position=0)]
        [ValidateScript({
            try { [System.Guid]::Parse($_) | Out-Null; $true } 
            catch { $false }
        })]
        [String]$TenantID
    , [Parameter(Position=1, Mandatory)]
        [pscredential]
        [System.Management.Automation.CredentialAttribute()]
        $Credential
    , [Parameter()]
        [ValidateSet('UserPrincipal', 'ServicePrincipal')]
        [String]$AuthenticationType = 'UserPrincipal'
)
Try
{
    $Username = $Credential.Username
    $Password = $Credential.Password

    If ($AuthenticationType -ieq 'UserPrincipal') {
        # Set well-known client ID for Azure PowerShell
        $clientId = '1950a258-227b-4e31-a9cf-717495945fc2'

        # Set Resource URI to Azure Service Management API
        $resourceAppIdURI = 'https://management.azure.com/'

        # Set Authority to Azure AD Tenant
        $authority = 'https://login.microsoftonline.com/common/' + $TenantID
        Write-Verbose "Authority: $authority"

        $AADcredential = [Microsoft.IdentityModel.Clients.ActiveDirectory.UserCredential]::new($UserName, $Password)
        $authContext = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext]::new($authority)
        $authResult = $authContext.AcquireTokenAsync($resourceAppIdURI,$clientId,$AADcredential)
        $Token = $authResult.Result.CreateAuthorizationHeader()
    }
    else {
        # Set Resource URI to Azure Service Management API
        $resourceAppIdURI = 'https://management.core.windows.net/'

        # Set Authority to Azure AD Tenant
        $authority = 'https://login.windows.net/' + $TenantId

        $ClientCred = [Microsoft.IdentityModel.Clients.ActiveDirectory.ClientCredential]::new($UserName, $Password)
        $authContext = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext]::new($authority)
        $authResult = $authContext.AcquireTokenAsync($resourceAppIdURI,$ClientCred)
        $Token = $authResult.Result.CreateAuthorizationHeader()
    }
}
Catch
{
    Throw $_
    Write-Error -Message 'Failed to aquire Azure AD token'
}
$Token