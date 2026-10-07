[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$PrivateLinkServiceName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$connections = az network private-link-service show `
    --resource-group $ResourceGroupName `
    --name $PrivateLinkServiceName `
    --query privateEndpointConnections `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read Private Link Service connections.'
}

$pending = @(
    @($connections) |
    Where-Object { $_.privateLinkServiceConnectionState.status -eq 'Pending' }
)
if ($pending.Count -ne 1) {
    throw "Expected exactly one pending connection, but found $($pending.Count). Approve the intended connection manually when multiple requests exist."
}

az network private-link-service connection update `
    --ids $pending[0].id `
    --connection-status Approved `
    --description 'Approved for Microsoft Fabric managed private endpoint' `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Private endpoint connection approval failed.'
}

az network private-link-service show `
    --resource-group $ResourceGroupName `
    --name $PrivateLinkServiceName `
    --query "privateEndpointConnections[?id=='$($pending[0].id)'] | [0]" `
    --output json