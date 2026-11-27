#requires -Version 7.0
<#
.SYNOPSIS
    Deploys ONE isolated artifact root using Azure APIOps Publisher v7.0.2.
.DESCRIPTION
    Run this script twice, sequentially, inside an authenticated AzureCLI@2
    task (scriptType: pscore): first -Stage Fragments, then -Stage Global.
    Uses APIOps Publisher for ALL writes to APIM. Azure CLI/REST is used
    for preflight checks and read-only post-deployment verification.
.EXAMPLE
    ./scripts/deploy-shared-policies.ps1 -Stage Fragments -ArtifactsRoot ./artifacts `
      -TargetSubscriptionId 'subscription-guid' -TargetResourceGroup 'my-rg' -TargetApimName 'my-apim'
.EXAMPLE
    ./scripts/deploy-shared-policies.ps1 -Stage Global -ArtifactsRoot ./artifacts `
      -TargetSubscriptionId 'subscription-guid' -TargetResourceGroup 'my-rg' -TargetApimName 'my-apim'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Fragments', 'Global')]
    [string] $Stage,

    [Parameter(Mandatory = $true)]
    [string] $ArtifactsRoot,

    [Parameter(Mandatory = $true)]
    [string] $TargetSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string] $TargetResourceGroup,

    [Parameter(Mandatory = $true)]
    [string] $TargetApimName,

    [ValidateSet('v7.0.2')]
    [string] $PublisherVersion = 'v7.0.2',

    [string] $ArmApiVersion = '2024-05-01',

    [string] $ExpectedPublisherSha256 = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fragments = @('apim-log-incoming-requests', 'apim-log-policy-error', 'apim-log-custom-rejection')
$ArtifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot)
$stageFolder = if ($Stage -eq 'Fragments') { 'fragments' } else { 'global' }
$publishRoot = Join-Path $ArtifactsRoot $stageFolder

if (-not (Test-Path -LiteralPath $publishRoot -PathType Container)) {
    throw "Missing $Stage artifact root: $publishRoot"
}

function Assert-Xml {
    param([string] $XmlText, [string] $ExpectedRoot)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($XmlText), $settings)
    try {
        $doc = [System.Xml.XmlDocument]::new()
        $doc.XmlResolver = $null
        $doc.Load($reader)
    }
    finally { $reader.Dispose() }
    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.Name -cne $ExpectedRoot) {
        throw "Invalid XML root: expected <$ExpectedRoot>."
    }
    return $doc
}

function Assert-OnlyFiles {
    param([string] $Root, [string[]] $AllowedFiles)
    $actualFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\','/')
    })
    $missing = @($AllowedFiles | Where-Object { $actualFiles -cnotcontains $_ })
    $unexpected = @($actualFiles | Where-Object { $AllowedFiles -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        throw "Unexpected $Stage artifact contents. Missing: [$($missing -join ', ')]. Unexpected: [$($unexpected -join ', ')]."
    }
}

# Hard stop if the wrong artifact root is passed to Publisher.
if ($Stage -eq 'Fragments') {
    # Publisher v7.0.2 uses "policy fragments" (with a space) and separate XML files.
    $expected = @($fragments | ForEach-Object {
        "policy fragments/$_/policyFragmentInformation.json"
        "policy fragments/$_/policy.xml"
    })
    Assert-OnlyFiles -Root $publishRoot -AllowedFiles $expected
    foreach ($name in $fragments) {
        $fragmentFolder = Join-Path (Join-Path $publishRoot 'policy fragments') $name
        $jsonPath = Join-Path $fragmentFolder 'policyFragmentInformation.json'
        $xmlPath = Join-Path $fragmentFolder 'policy.xml'
        $item = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$item.properties.description)) {
            throw "Missing APIOps fragment description: $jsonPath"
        }
        # Metadata must not contain policy XML in this v7.0.2 artifact format.
        if ($null -ne $item.properties.PSObject.Properties['value'] -or
            $null -ne $item.properties.PSObject.Properties['format']) {
            throw "Unexpected inline XML in fragment metadata: $jsonPath"
        }
        $fragmentXml = Get-Content -LiteralPath $xmlPath -Raw -Encoding utf8
        $null = Assert-Xml -XmlText $fragmentXml -ExpectedRoot 'fragment'
    }
}
else {
    Assert-OnlyFiles -Root $publishRoot -AllowedFiles @('policy.xml')
    $globalXml = Get-Content -LiteralPath (Join-Path $publishRoot 'policy.xml') -Raw -Encoding utf8
    $null = Assert-Xml -XmlText $globalXml -ExpectedRoot 'policies'
}

if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Run this script inside an authenticated AzureCLI@2 task.'
}

& az account set --subscription $TargetSubscriptionId
if ($LASTEXITCODE -ne 0) { throw 'Could not select target Azure subscription.' }

$serviceId = (& az apim show --resource-group $TargetResourceGroup --name $TargetApimName --query id -o tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serviceId)) {
    throw 'Target APIM instance does not exist or is not accessible; refusing to continue.'
}
$serviceId = ([string]$serviceId).TrimEnd('/')
$expectedServiceId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroup/providers/Microsoft.ApiManagement/service/$TargetApimName"
if (-not $serviceId.Equals($expectedServiceId, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected APIM target id: $serviceId"
}

# Read-only ARM verification. These calls do NOT create/update resources.
function Get-ApimResource {
    param([string] $ResourcePath)
    $uri = "https://management.azure.com$serviceId/$ResourcePath" + "?api-version=$ArmApiVersion&format=xml"
    $result = (& az rest --method get --url $uri --output json)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($result -join ''))) {
        throw "Unable to read APIM resource: $ResourcePath"
    }
    return (($result -join "`n") | ConvertFrom-Json)
}

# Basic read-only verification: resource exists, has XML and expected root element.
# APIOps Publisher/APIM validates policy semantics at deployment time.
# This intentionally does NOT compare the deployed XML to the artifact.
function Assert-FragmentDeployed {
    param([string] $Name, [string] $Prefix)

    $actual = Get-ApimResource -ResourcePath "policyFragments/$Name"
    if ([string]::IsNullOrWhiteSpace([string]$actual.properties.value)) {
        throw "Fragment '$Name' has no deployed XML."
    }
    try {
        $null = Assert-Xml -XmlText ([string]$actual.properties.value) -ExpectedRoot 'fragment'
    }
    catch {
        throw "Deployed fragment '$Name' has invalid XML: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$actual.properties.description)) {
