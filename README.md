# Fabric MPE relay for an existing workspace

This package deploys only the customer-owned Azure resources:

- Resource group
- VNet and three subnets
- NSG
- Static VM public IP
- Internal Standard Load Balancer
- Ubuntu relay VM and NIC
- Azure Private Link Service

It does not create a Fabric capacity, workspace, or notebook.

## 1. Deploy Azure resources

```powershell
.\Deploy-AzureOnly.ps1 `
    -TargetFqdn 'api.contoso.com' `
        -TargetPort 443 `
    -Prefix 'contosoapi' `
    -ResourceGroupName 'rg-contoso-fabric-relay' `
    -Location 'southeastasia'
```

The script resolves the first public IPv4 address for the target FQDN and configures kernel DNAT/SNAT on the VM. Use `-TargetIPv4` when the target IP must be selected explicitly.

## Port model

`TargetPort` is mandatory. The deployment never guesses the service port. The supplied value is applied consistently to the complete TCP path:

```text
Notebook target FQDN:443
    -> MPE and Private Link Service
    -> ILB frontend:443
    -> ILB backend and health probe:443
    -> VM DNAT
    -> resolved target IPv4:443
```

`targetFQDNs` contains only DNS names. Ports are configured by the client URL, load-balancer rule, and VM forwarding rule.

For an API on port 8443:

```powershell
.\Deploy-AzureOnly.ps1 `
    -TargetFqdn 'api.contoso.com' `
    -TargetPort 8443 `
    -Prefix 'contosoapi8443'
```

The application must then connect to `https://api.contoso.com:8443`. Fabric associates `api.contoso.com` with the MPE, while the ILB and VM forward TCP 8443.

For a single Kafka listener, the same mechanism can forward a TCP port such as 9093:

```powershell
.\Deploy-AzureOnly.ps1 `
    -TargetFqdn 'broker1.kafka.contoso.com' `
    -TargetPort 9093 `
    -Prefix 'kafkabroker1'
```

Kafka commonly returns broker addresses from `advertised.listeners`. Every advertised broker FQDN and port must be reachable through Fabric. A single bootstrap-server MPE and relay is insufficient when the client is redirected to multiple brokers. In that case, create a forwarding path for each advertised broker or use a Kafka-aware network design.

This template intentionally deploys one forwarding stack for one target FQDN. Pure kernel DNAT cannot distinguish `api-a.contoso.com:443` from `api-b.contoso.com:443` after both connections reach the same VM IP and port.

For multiple HTTPS APIs, choose one of these designs:

1. Deploy this template once per target FQDN with a unique prefix. Each target gets its own MPE, PLS, ILB, and relay VM. This is the simplest and most isolated design.
2. Build a shared relay tier with one MPE and PLS per FQDN, one ILB frontend IP per PLS, and a unique ILB backend port per target on the shared VM. Each backend port then has its own DNAT rule to the corresponding target IPv4 and port. This reduces VM cost but requires a different multi-endpoint template.

Do not point multiple FQDNs at one PLS/ILB frontend on TCP 443 and expect iptables to select the target by HTTPS hostname. That requires an SNI-aware or HTTP proxy and is not kernel-only forwarding.

Review `deployment-state.json` after deployment. The important values are:

- `privateLinkServiceId`
- `privateLinkServiceName`
- `relayPublicIp`
- `targetIPv4`

## 2. Create an MPE in an existing Fabric workspace

```powershell
$state = Get-Content .\deployment-state.json -Raw | ConvertFrom-Json

.\New-FabricMpe.ps1 `
    -WorkspaceId '<existing-workspace-guid>' `
    -PrivateLinkServiceResourceId $state.privateLinkServiceId `
    -TargetFqdn $state.targetFqdn `
    -MpeName 'contoso-api-relay'
```

The caller must be a workspace administrator and must be able to acquire a token for `https://api.fabric.microsoft.com`.

## 3. Approve the connection

```powershell
.\Approve-FabricConnection.ps1 `
    -ResourceGroupName $state.resourceGroupName `
    -PrivateLinkServiceName $state.privateLinkServiceName
```

The approval script intentionally stops unless exactly one pending request exists.

## Important production constraints

- The Notebook must call the original HTTPS FQDN, not the ILB IP.
- The target FQDN must contain at least three DNS labels for this Fabric MPE path.
- The VM performs TCP pass-through and does not terminate TLS.
- The current DNAT rule uses one fixed IPv4 address. It does not automatically follow DNS changes or support a multi-IP/CDN target.
- Redirect, authentication, and token-service FQDNs may require separate MPE and forwarding paths.
- The template uses `visibility.subscriptions: ["*"]` for compatibility with the Fabric-managed consumer. Review and restrict this setting if the applicable Fabric subscription identity is known.
- The target service should allowlist the `relayPublicIp` value.