#requires -Version 7.0
<#
.SYNOPSIS
    Builds two independent APIOps Publisher artifact roots.
.DESCRIPTION
    Source layout:
      global/policy.xml
      policyFragments/<fragment-id>/policy.xml

    Output layout:
      <OutputRoot>/fragments/policyFragments/<fragment-id>/policyFragmentInformation.json
      <OutputRoot>/global/policy.xml

    This script NEVER calls Azure or creates APIM resources.
.EXAMPLE
    ./scripts/build-artifacts.ps1 -RepoRoot . -OutputRoot ./artifacts
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = '',
    [string] $OutputRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepoRoot 'artifacts'
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$sourceFragments = Join-Path $RepoRoot 'policyFragments'
$sourceGlobal = Join-Path $RepoRoot 'global'

# Safeguard: never clean folders containing source XML.
$sep = [System.IO.Path]::DirectorySeparatorChar
foreach ($protected in @($RepoRoot, $sourceFragments, $sourceGlobal)) {
    $p = [System.IO.Path]::GetFullPath($protected).TrimEnd([char[]]@('/','\'))
    $o = $OutputRoot.TrimEnd([char[]]@('/','\'))
    if ($o.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($o + $sep, [StringComparison]::OrdinalIgnoreCase) -or
        $o.StartsWith($p + $sep, [StringComparison]::OrdinalIgnoreCase) -and
        -not $p.Equals($RepoRoot.TrimEnd([char[]]@('/','\')), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe OutputRoot '$OutputRoot': overlaps source folder '$p'."
    }
}

function Read-ValidatedXml {
    param([string] $File, [string] $ExpectedRoot)

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "Required XML file not found: $File"
    }
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($File, $settings)
    try {
        $doc = [System.Xml.XmlDocument]::new()
        $doc.XmlResolver = $null
        $doc.PreserveWhitespace = $true
        $doc.Load($reader)
    }
    finally {
        $reader.Dispose()
    }
    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.Name -cne $ExpectedRoot) {
        throw "Invalid XML root in $File; expected <$ExpectedRoot>."
    }
    return $doc
}

$fragmentDescriptions = [ordered]@{
    'apim-log-incoming-requests' = 'Shared incoming request logging'
    'apim-log-policy-error'   = 'Shared global error logging'
    'apim-log-custom-rejection' = 'Shared API and operation custom rejection logging'
}

# Validate everything before replacing any existing generated artifacts.
$globalSource = Join-Path $sourceGlobal 'policy.xml'
$globalDoc = Read-ValidatedXml -File $globalSource -ExpectedRoot 'policies'
foreach ($section in @('inbound','backend','outbound','on-error')) {
    if ($null -eq $globalDoc.DocumentElement.SelectSingleNode($section)) {
        throw "Global policy missing <$section>: $globalSource"
    }
}
if ($null -eq $globalDoc.DocumentElement.SelectSingleNode("inbound/include-fragment[@fragment-id='apim-log-incoming-requests']")) {
    throw 'Global inbound policy must reference apim-log-incoming-requests.'
}
if ($null -eq $globalDoc.DocumentElement.SelectSingleNode("on-error/include-fragment[@fragment-id='apim-log-policy-error']")) {
    throw 'Global on-error policy must reference apim-log-policy-error.'
}
if ($null -eq $globalDoc.DocumentElement.SelectSingleNode('inbound/cors')) {
    throw 'Global inbound CORS policy was not found. Preserve the existing CORS configuration.'
}

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$xmlByFragment = @{}
foreach ($name in $fragmentDescriptions.Keys) {
    $xmlPath = Join-Path (Join-Path $sourceFragments $name) 'policy.xml'
    $doc = Read-ValidatedXml -File $xmlPath -ExpectedRoot 'fragment'
    if ($doc.DocumentElement.SelectNodes('*').Count -eq 0) {
        throw "Fragment '$name' is empty: $xmlPath"
    }
    $forbidden = $doc.SelectNodes('//*[local-name()="base" or local-name()="inbound" or local-name()="backend" or local-name()="outbound" or local-name()="on-error" or local-name()="include-fragment"]')
    if ($forbidden.Count -gt 0) {
        throw "Fragment '$name' contains unsupported <base>, policy-section or nested fragment elements."
    }
    $xmlByFragment[$name] = [System.IO.File]::ReadAllText($xmlPath, $utf8)
}
$globalXml = [System.IO.File]::ReadAllText($globalSource, $utf8)

$fragmentsOutput = Join-Path $OutputRoot 'fragments'
$globalOutput = Join-Path $OutputRoot 'global'
foreach ($dir in @($fragmentsOutput, $globalOutput)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
    [void][System.IO.Directory]::CreateDirectory($dir)
}

foreach ($name in $fragmentDescriptions.Keys) {
    $destination = Join-Path (Join-Path $fragmentsOutput 'policyFragments') $name
    [void][System.IO.Directory]::CreateDirectory($destination)
    $json = [ordered]@{
        properties = [ordered]@{
            description = $fragmentDescriptions[$name]
            format      = 'rawxml'
            value       = $xmlByFragment[$name]
        }
    } | ConvertTo-Json -Depth 8
    $jsonPath = Join-Path $destination 'policyFragmentInformation.json'
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8)
    Write-Host "PACKAGED fragment: $name"
}

[System.IO.File]::WriteAllText((Join-Path $globalOutput 'policy.xml'), $globalXml, $utf8)
Write-Host "PACKAGED global policy."
Write-Host "SUCCESS: Two isolated artifact roots created under $OutputRoot"
