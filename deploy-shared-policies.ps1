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
    $uri = "https://management.azure.com$serviceId/$ResourcePath" + "?api-version=$ArmApiVersion&format=xml"
    $result = (& az rest --method get --url $uri --output json)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($result -join ''))) {
        throw "Unable to read APIM resource: $ResourcePath"
    }
    return (($result -join "`n") | ConvertFrom-Json)
}

# Compare XML structure and values instead of serialized OuterXml. Azure APIM may
# round-trip XML with different attribute ordering, indentation or empty-tag style.
# This is intentionally strict on element order, names, attribute values and text.
function Assert-XmlEquivalent {
    param(
        [System.Xml.XmlNode] $Expected,
        [System.Xml.XmlNode] $Actual,
        [string] $Location = '/fragment'
    )

    if ($Expected.NodeType -ne $Actual.NodeType -or
        $Expected.LocalName -cne $Actual.LocalName -or
        $Expected.NamespaceURI -cne $Actual.NamespaceURI) {
        throw "XML structural mismatch at $Location (node name or type differs)."
    }

    if ($Expected.NodeType -eq [System.Xml.XmlNodeType]::Element) {
        $expectedAttrs = @($Expected.Attributes | Where-Object { $_.NamespaceURI -ne 'http://www.w3.org/2000/xmlns/' })
        $actualAttrs = @($Actual.Attributes | Where-Object { $_.NamespaceURI -ne 'http://www.w3.org/2000/xmlns/' })
        if ($expectedAttrs.Count -ne $actualAttrs.Count) {
            throw "XML attribute count mismatch at $Location."
        }
        foreach ($attr in $expectedAttrs) {
            $other = $Actual.Attributes.GetNamedItem($attr.LocalName, $attr.NamespaceURI)
            if ($null -eq $other) {
                throw "Missing deployed XML attribute '$($attr.Name)' at $Location."
            }
            if ($attr.Value -cne $other.Value) {
                throw "Deployed XML attribute value differs at $Location/@$($attr.Name)."
            }
        }

        # Document loading already discards insignificant whitespace; comments
        # have no effect on policy execution and are intentionally ignored.
        $expectedChildren = @($Expected.ChildNodes | Where-Object { $_.NodeType -ne [System.Xml.XmlNodeType]::Comment })
        $actualChildren = @($Actual.ChildNodes | Where-Object { $_.NodeType -ne [System.Xml.XmlNodeType]::Comment })
        if ($expectedChildren.Count -ne $actualChildren.Count) {
            throw "XML child-element/text count mismatch at $Location (expected $($expectedChildren.Count), deployed $($actualChildren.Count))."
        }
        for ($i = 0; $i -lt $expectedChildren.Count; $i++) {
            $child = $expectedChildren[$i]
            Assert-XmlEquivalent -Expected $child -Actual $actualChildren[$i] -Location "$Location/$($child.LocalName)[$i]"
        }
    }
    elseif ($Expected.Value -cne $Actual.Value) {
        throw "Deployed XML text/value differs at $Location."
    }
}

# Compare the actual deployed content with the expected source, not merely existence.
function Assert-FragmentMatchesArtifact {
    param([string] $Name, [string] $Prefix)
    $fragmentFolder = Join-Path (Join-Path (Join-Path $ArtifactsRoot 'fragments') 'policy fragments') $Name
    $metadataPath = Join-Path $fragmentFolder 'policyFragmentInformation.json'
    $expectedPolicyPath = Join-Path $fragmentFolder 'policy.xml'
    if (-not (Test-Path -LiteralPath $metadataPath) -or
        -not (Test-Path -LiteralPath $expectedPolicyPath)) {
        throw "Expected packaged fragment files are missing for '$Name'."
    }
    $expectedMetadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
    $expectedPolicy = Get-Content -LiteralPath $expectedPolicyPath -Raw -Encoding utf8
    $actual = Get-ApimResource -ResourcePath "policyFragments/$Name"
    if ([string]::IsNullOrWhiteSpace([string]$actual.properties.value)) {
        throw "Fragment '$Name' has no deployed XML."
    }
    try {
        $expectedDoc = Assert-Xml -XmlText $expectedPolicy -ExpectedRoot 'fragment'
        $actualDoc = Assert-Xml -XmlText ([string]$actual.properties.value) -ExpectedRoot 'fragment'
    }
    catch {
        throw "Invalid deployed XML for fragment '$Name': $($_.Exception.Message)"
    }
    try {
        Assert-XmlEquivalent -Expected $expectedDoc.DocumentElement -Actual $actualDoc.DocumentElement -Location "/fragment/$Name"
    }
    catch {
        throw "Deployed XML mismatch for fragment '$Name': $($_.Exception.Message)"
    }
    if ([string]$actual.properties.description -cne [string]$expectedMetadata.properties.description) {
        throw "Deployed description for fragment '$Name' does not match the artifact."
    }
    Write-Host "$Prefix fragment content and description match: $Name"
}

# Do not replace global policy until ALL fragment resources match current build artifacts.
if ($Stage -eq 'Global') {
    foreach ($name in $fragments) {
        Assert-FragmentMatchesArtifact -Name $name -Prefix 'PREFLIGHT VERIFIED'
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
    Write-Host "Publisher input files:"
    Get-ChildItem -LiteralPath $publishRoot -Recurse -File | ForEach-Object {
        Write-Host ('  ' + [System.IO.Path]::GetRelativePath($publishRoot, $_.FullName))
    }
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

# Verify actual resource contents, not just existence, after Publisher succeeds.
if ($Stage -eq 'Fragments') {
    foreach ($name in $fragments) {
        Assert-FragmentMatchesArtifact -Name $name -Prefix 'VERIFIED'
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
