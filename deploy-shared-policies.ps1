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
    $expected = @($fragments | ForEach-Object { "policyFragments/$_/policyFragmentInformation.json" })
    Assert-OnlyFiles -Root $publishRoot -AllowedFiles $expected
    foreach ($name in $fragments) {
        $jsonPath = Join-Path (Join-Path (Join-Path $publishRoot 'policyFragments') $name) 'policyFragmentInformation.json'
        $item = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($item.properties.format -cne 'rawxml' -or [string]::IsNullOrWhiteSpace($item.properties.value)) {
            throw "Invalid APIOps fragment artifact: $jsonPath"
        }
        $null = Assert-Xml -XmlText $item.properties.value -ExpectedRoot 'fragment'
    }
}
else {
    Assert-OnlyFiles -Root $publishRoot -AllowedFiles @('policy.xml')
    $globalXml = Get-Content -LiteralPath (Join-Path $publishRoot 'policy.xml') -Raw -Encoding utf8
    $globalDoc = Assert-Xml -XmlText $globalXml -ExpectedRoot 'policies'
    foreach ($name in @('apim-log-incoming-requests', 'apim-log-policy-error')) {
        if ($null -eq $globalDoc.SelectSingleNode("//include-fragment[@fragment-id='$name']")) {
            throw "Global policy artifact does not reference '$name'."
        }
    }
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
    $uri = "https://management.azure.com$serviceId/$ResourcePath" + "?api-version=$ArmApiVersion&format=rawxml"
    $result = (& az rest --method get --url $uri --output json)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($result -join ''))) {
        throw "Unable to read APIM resource: $ResourcePath"
    }
    return (($result -join "`n") | ConvertFrom-Json)
}

# Do not replace global policy until ALL fragment resources are visible.
if ($Stage -eq 'Global') {
    foreach ($name in $fragments) {
        $existing = Get-ApimResource -ResourcePath "policyFragments/$name"
        if ([string]::IsNullOrWhiteSpace([string]$existing.properties.value)) {
            throw "Required fragment '$name' is missing or empty in Dev APIM."
        }
        $null = Assert-Xml -XmlText ([string]$existing.properties.value) -ExpectedRoot 'fragment'
        Write-Host "PREFLIGHT fragment exists: $name"
    }
}

$assetName = if ($IsWindows) { 'publisher-win-x64.zip' }
             elseif ($IsLinux) { 'publisher-linux-x64.zip' }
             else { throw 'Use a Windows or Linux x64 PowerShell 7 Azure DevOps agent.' }
$exeName = if ($IsWindows) { 'publisher.exe' } else { 'publisher' }

$tempBase = if (-not [string]::IsNullOrWhiteSpace($env:AGENT_TEMPDIRECTORY)) {
    $env:AGENT_TEMPDIRECTORY
} else {
    [System.IO.Path]::GetTempPath()
}
$workDir = Join-Path $tempBase ("apim-publisher-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($workDir)

try {
    $downloadUri = "https://github.com/Azure/apiops/releases/download/$PublisherVersion/$assetName"
    $zipPath = Join-Path $workDir $assetName
    $extractDir = Join-Path $workDir 'publisher'
    Write-Host "Downloading APIOps Publisher $PublisherVersion for $Stage..."
    Invoke-WebRequest -Uri $downloadUri -OutFile $zipPath

    if (-not [string]::IsNullOrWhiteSpace($ExpectedPublisherSha256)) {
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($actualHash -ine $ExpectedPublisherSha256) {
            throw "Publisher ZIP SHA256 does not match the expected value."
        }
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $exePath = Join-Path $extractDir $exeName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Publisher binary missing from downloaded archive: $exePath"
    }
    if ($IsLinux) {
        & chmod +x $exePath
        if ($LASTEXITCODE -ne 0) { throw 'Could not make Publisher executable.' }
    }

    $token = (& az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
        throw 'Could not acquire an ARM token from the Azure CLI login.'
    }

    $env:AZURE_SUBSCRIPTION_ID = $TargetSubscriptionId
    $env:AZURE_RESOURCE_GROUP_NAME = $TargetResourceGroup
    $env:API_MANAGEMENT_SERVICE_NAME = $TargetApimName
    $env:API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH = $publishRoot
    $env:ARM_API_VERSION = $ArmApiVersion
    $env:AZURE_BEARER_TOKEN = ($token -join '').Trim()
    Remove-Item Env:COMMIT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:CONFIGURATION_YAML_PATH -ErrorAction SilentlyContinue

    Write-Host "PUBLISH Stage=$Stage; Target=$TargetApimName; ArtifactRoot=$publishRoot"
    & $exePath
    if ($LASTEXITCODE -ne 0) {
        throw "APIOps Publisher $PublisherVersion failed for $Stage (exit code $LASTEXITCODE)."
    }
    Write-Host "Publisher completed: $Stage"
}
finally {
    Remove-Item Env:AZURE_BEARER_TOKEN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Verify each resource via read-only GET after Publisher succeeds.
if ($Stage -eq 'Fragments') {
    foreach ($name in $fragments) {
        $resource = Get-ApimResource -ResourcePath "policyFragments/$name"
        if ([string]::IsNullOrWhiteSpace([string]$resource.properties.value)) {
            throw "Publisher exited successfully, but fragment '$name' is missing or empty."
        }
        $null = Assert-Xml -XmlText ([string]$resource.properties.value) -ExpectedRoot 'fragment'
        Write-Host "VERIFIED fragment resource: $name"
    }
}
else {
    $resource = Get-ApimResource -ResourcePath 'policies/policy'
    if ([string]::IsNullOrWhiteSpace([string]$resource.properties.value)) {
        throw 'Global policy not readable after Publisher deployment.'
    }
    $deployedPolicy = Assert-Xml -XmlText ([string]$resource.properties.value) -ExpectedRoot 'policies'
    if ($null -eq $deployedPolicy.SelectSingleNode("/policies/inbound/include-fragment[@fragment-id='apim-log-incoming-requests']") -or
        $null -eq $deployedPolicy.SelectSingleNode("/policies/on-error/include-fragment[@fragment-id='apim-log-policy-error']")) {
        throw 'Deployed global policy is missing a required fragment reference.'
    }
    Write-Host 'VERIFIED global policy resource and references.'
}
Write-Host "SUCCESS: APIOps Publisher $PublisherVersion deployed and verified $Stage."
