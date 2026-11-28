#requires -Version 7.0
<#
.SYNOPSIS
    Builds isolated APIOps Publisher v7.0.2 artifact roots from repository XML/JSON.
.DESCRIPTION
    Repository input:
      policyFragments/<fragment-id>/policy.xml
      policyFragments/<fragment-id>/policyFragmentInformation.json
      global/policy.xml

    Artifact output:
      <OutputRoot>/fragments/policy fragments/<fragment-id>/policy.xml
      <OutputRoot>/fragments/policy fragments/<fragment-id>/policyFragmentInformation.json
      <OutputRoot>/global/policy.xml

    Every immediate folder under policyFragments is discovered automatically.
    The folder name becomes the APIM fragment ID. JSON supplies the description.
    No Azure resources are created or modified by this script.
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
$globalSource = Join-Path $sourceGlobal 'policy.xml'

if (-not (Test-Path -LiteralPath $sourceFragments -PathType Container)) {
    throw "Missing source policyFragments folder: $sourceFragments"
}

# Only generated directories may be deleted. Never clean the Git checkout,
# any ancestor of it, or a folder underneath sourceFragments/global.
$comparison = if ($IsWindows) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$sep = [System.IO.Path]::DirectorySeparatorChar
$out = [System.IO.Path]::TrimEndingDirectorySeparator($OutputRoot)
$rootPath = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetPathRoot($OutputRoot))
if ($out.Equals($rootPath, $comparison)) {
    throw "Unsafe OutputRoot '$OutputRoot': filesystem root is not permitted."
}
foreach ($protected in @($RepoRoot, $sourceFragments, $sourceGlobal)) {
    $p = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($protected))
    if ($out.Equals($p, $comparison) -or
        $out.StartsWith($p + $sep, $comparison) -and (-not $p.Equals([System.IO.Path]::TrimEndingDirectorySeparator($RepoRoot), $comparison)) -or
        $p.StartsWith($out + $sep, $comparison)) {
        throw "Unsafe OutputRoot '$OutputRoot': overlaps protected path '$protected'."
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
        $doc.Load($reader)
    }
    finally { $reader.Dispose() }
    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.Name -cne $ExpectedRoot) {
        throw "Invalid XML root in '$File'. Expected <$ExpectedRoot>."
    }
    return $doc
}

function Read-FragmentDescription {
    param([string] $JsonPath)
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
        throw "Missing fragment metadata JSON: $JsonPath"
    }
    try {
        $metadata = Get-Content -LiteralPath $JsonPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid fragment metadata JSON '$JsonPath': $($_.Exception.Message)"
    }
    if ($null -eq $metadata -or $null -eq $metadata.PSObject.Properties['properties']) {
        throw "Fragment metadata must contain a 'properties' object: $JsonPath"
    }
    $props = $metadata.properties
    if ($null -eq $props -or $null -eq $props.PSObject.Properties['description'] -or
        $props.description -isnot [string] -or
        [string]::IsNullOrWhiteSpace($props.description)) {
        throw "Fragment metadata must contain a non-empty string properties.description: $JsonPath"
    }
    if ($props.description.Length -gt 1000) {
        throw "Fragment description must be at most 1000 characters: $JsonPath"
    }
    if ($null -ne $props.PSObject.Properties['value'] -or
        $null -ne $props.PSObject.Properties['format']) {
        throw "Do not embed format/value in source metadata; use the separate policy.xml: $JsonPath"
    }
    return [string]$props.description
}

# Validate all source files before clearing any existing generated output.
$null = Read-ValidatedXml -File $globalSource -ExpectedRoot 'policies'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

$dirs = @(Get-ChildItem -LiteralPath $sourceFragments -Directory | Sort-Object Name)
if ($dirs.Count -eq 0) {
    throw "No fragment folders found directly under '$sourceFragments'."
}

$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$validated = @(
    foreach ($dir in $dirs) {
        $name = $dir.Name
        if ($name.Length -gt 80 -or
            $name -cnotmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') {
            throw "Invalid APIM fragment ID '$name'. Use 1-80 letters, digits, underscores or internal hyphens."
        }
        if (-not $seen.Add($name)) {
            throw "Duplicate APIM fragment ID (case-insensitive): '$name'."
        }

        $xmlPath = Join-Path $dir.FullName 'policy.xml'
        $jsonPath = Join-Path $dir.FullName 'policyFragmentInformation.json'
        $doc = Read-ValidatedXml -File $xmlPath -ExpectedRoot 'fragment'
        if ($doc.DocumentElement.SelectNodes('*').Count -eq 0) {
            throw "Fragment '$name' has no policy statements."
        }
        # APIM prohibits section wrappers, <base> and nested includes within fragments.
        $forbidden = $doc.SelectNodes('//*[local-name()="base" or local-name()="inbound" or local-name()="backend" or local-name()="outbound" or local-name()="on-error" or local-name()="include-fragment"]')
        if ($forbidden.Count -gt 0) {
            throw "Fragment '$name' contains unsupported section, base, or include-fragment elements."
        }
        $xmlContent = [System.IO.File]::ReadAllText($xmlPath, $utf8)
        if ($utf8.GetByteCount($xmlContent) -gt 512KB) {
            throw "Fragment '$name' exceeds the APIM 512 KB fragment size limit."
        }
        $description = Read-FragmentDescription -JsonPath $jsonPath
        [pscustomobject]@{
            Name = $name
            PolicyXml = $xmlContent
            Description = $description
        }
    }
)

$fragmentsOutput = Join-Path $OutputRoot 'fragments'
$globalOutput = Join-Path $OutputRoot 'global'
foreach ($dir in @($fragmentsOutput, $globalOutput)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
    [void][System.IO.Directory]::CreateDirectory($dir)
}

foreach ($item in $validated) {
    # The literal space in 'policy fragments' is required by APIOps v7.0.2.
    $destination = Join-Path (Join-Path $fragmentsOutput 'policy fragments') $item.Name
    [void][System.IO.Directory]::CreateDirectory($destination)

    $metadata = [ordered]@{
        properties = [ordered]@{
            description = $item.Description
        }
    } | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText((Join-Path $destination 'policyFragmentInformation.json'), $metadata, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $destination 'policy.xml'), $item.PolicyXml, $utf8)
    Write-Host "PACKAGED fragment: $($item.Name)"
}

[System.IO.File]::WriteAllText(
    (Join-Path $globalOutput 'policy.xml'),
    [System.IO.File]::ReadAllText($globalSource, $utf8),
    $utf8
)
Write-Host "PACKAGED global policy."
Write-Host "SUCCESS: $($validated.Count) fragments and global policy packaged under $OutputRoot"
