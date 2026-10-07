[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9.-]+$')]
    [string]$TargetFqdn,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]{3,20}$')]
    [string]$Prefix,

    [string]$ResourceGroupName = "rg-$Prefix-fabric-relay",
    [string]$Location = 'southeastasia',
    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int]$TargetPort,
    [string]$TargetIPv4,
    [string]$VmSize = 'Standard_D2als_v7',
    [string]$SshKeyPath = "C:\Copilot\temp\$(Get-Date -Format yyyyMMdd)\$Prefix-relay"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$templatePath = Join-Path $PSScriptRoot 'azuredeploy.json'
$statePath = Join-Path $PSScriptRoot 'deployment-state.json'
$tempDirectory = "C:\Copilot\temp\$(Get-Date -Format yyyyMMdd)"
$parametersPath = Join-Path $tempDirectory "$Prefix-azuredeploy.parameters.json"

if (($TargetFqdn.TrimEnd('.').Split('.')).Count -lt 3) {
    throw "TargetFqdn must contain at least three DNS labels for the Fabric MPE path: $TargetFqdn"
}

az account show --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not signed in. Run az login, then retry.'
}

$subscriptionId = az account show --query id --output tsv
if (-not $TargetIPv4) {
    $TargetIPv4 = Resolve-DnsName $TargetFqdn -Type A -ErrorAction Stop |
        Where-Object Type -eq 'A' |
        Select-Object -First 1 -ExpandProperty IPAddress
}
if (-not $TargetIPv4) {
    throw "No IPv4 address was resolved for $TargetFqdn."
}

foreach ($provider in 'Microsoft.Network', 'Microsoft.Compute') {
    az provider register --namespace $provider --wait --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register $provider."
    }
}

if (-not (Test-Path "$SshKeyPath.pub")) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SshKeyPath) | Out-Null
    & ssh-keygen -q -t ed25519 -N '' -f $SshKeyPath
    if ($LASTEXITCODE -ne 0) {
        throw 'ssh-keygen failed.'
    }
}
$sshPublicKey = Get-Content "$SshKeyPath.pub" -Raw

New-Item -ItemType Directory -Force -Path $tempDirectory | Out-Null
$armParameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        prefix = @{ value = $Prefix }
        location = @{ value = $Location }
        sshPublicKey = @{ value = $sshPublicKey }
        targetFqdn = @{ value = $TargetFqdn }
        targetIPv4 = @{ value = $TargetIPv4 }
        targetPort = @{ value = $TargetPort }
        vmSize = @{ value = $VmSize }
    }
}
$armParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $parametersPath -Encoding utf8

az group create `
    --name $ResourceGroupName `
    --location $Location `
    --tags purpose=fabric-mpe-kernel-relay `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Resource group creation failed.'
}

az deployment group validate `
    --resource-group $ResourceGroupName `
    --template-file $templatePath `
    --parameters "@$parametersPath" `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'ARM validation failed.'
}

$deployment = az deployment group create `
    --name "$Prefix-azure-relay" `
    --resource-group $ResourceGroupName `
    --template-file $templatePath `
    --parameters "@$parametersPath" `
    --only-show-errors `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'ARM deployment failed.'
}

$outputs = $deployment.properties.outputs
$state = [ordered]@{
    subscriptionId = $subscriptionId
    resourceGroupName = $ResourceGroupName
    prefix = $Prefix
    location = $Location
    targetFqdn = $outputs.targetFqdn.value
    targetIPv4 = $outputs.targetIPv4.value
    targetPort = $outputs.targetPort.value
    privateLinkServiceId = $outputs.privateLinkServiceId.value
    privateLinkServiceName = $outputs.privateLinkServiceName.value
    internalLoadBalancerIp = $outputs.internalLoadBalancerIp.value
    relayPublicIp = $outputs.relayPublicIp.value
    sshPrivateKeyPath = $SshKeyPath
}
$state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding utf8
Remove-Item $parametersPath -Force -ErrorAction SilentlyContinue
$state | ConvertTo-Json -Depth 10