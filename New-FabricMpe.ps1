[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [Parameter(Mandatory)]
    [string]$PrivateLinkServiceResourceId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9.-]+$')]
    [string]$TargetFqdn,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$MpeName,

    [string]$RequestMessage = 'Fabric access through customer-managed Private Link Service'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (($TargetFqdn.TrimEnd('.').Split('.')).Count -lt 3) {
    throw "TargetFqdn must contain at least three DNS labels: $TargetFqdn"
}

$token = az account get-access-token `
    --resource https://api.fabric.microsoft.com `
    --query accessToken `
    --output tsv
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Could not acquire a Microsoft Fabric API token.'
}
$headers = @{ Authorization = "Bearer $token" }
$mpeUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints"

$managedPrivateEndpoints = Invoke-RestMethod -Method Get -Uri $mpeUri -Headers $headers
$existing = @($managedPrivateEndpoints.value) |
    Where-Object name -eq $MpeName |
    Select-Object -First 1
if ($existing) {
    $existing | ConvertTo-Json -Depth 20
    return
}

$body = @{
    name = $MpeName
    targetPrivateLinkResourceId = $PrivateLinkServiceResourceId
    targetFQDNs = @($TargetFqdn)
    requestMessage = $RequestMessage
} | ConvertTo-Json -Depth 10

$mpe = Invoke-RestMethod `
    -Method Post `
    -Uri $mpeUri `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body $body

$mpe | ConvertTo-Json -Depth 20