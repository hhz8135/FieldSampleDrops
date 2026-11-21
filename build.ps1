[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = $PSScriptRoot
$ArchiveName = '9ba626afa44a3aa3.patch_0'
$RuntimeModule = 'mods/skyeshade/hd2runtime'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Fail([string] $Message) { throw "HD2Runtime mod build: $Message" }
function JsonBytes($Value) { return $Utf8.GetBytes(($Value | ConvertTo-Json -Depth 12) + "`n") }
function TextBytes([string] $Value) { return $Utf8.GetBytes($Value) }

$Compiler = @'
using System;
using System.IO;
using System.Text;

public static class HD2StarterArchive
{
    const ulong Mix = 0xC6A4A7935BD1E995UL;
    const ulong LuaType = 0xA14E8DFA2CD117E2UL;

    public static ulong ResourceHash(string name)
    {
        byte[] data = new UTF8Encoding(false).GetBytes(name);
        unchecked {
            ulong result = (ulong)data.Length * Mix;
            int complete = data.Length / 8 * 8;
            for (int at = 0; at < complete; at += 8) {
                ulong word = BitConverter.ToUInt64(data, at);
                word *= Mix;
                word ^= word >> 47;
                result = (result ^ (word * Mix)) * Mix;
            }
            if (complete != data.Length) {
                ulong tail = 0;
                for (int i = complete; i < data.Length; ++i)
                    tail |= (ulong)data[i] << ((i - complete) * 8);
                result = (result ^ tail) * Mix;
            }
            result ^= result >> 47;
            result *= Mix;
            return result ^ (result >> 47);
        }
    }

    static void Zeros(BinaryWriter writer, int count) { writer.Write(new byte[count]); }

    public static byte[] Build(string name, byte[] body)
    {
        const uint dataOffset = 192;
        uint resourceLength = checked((uint)body.Length + 8U);
        uint padding = (uint)((16 - (resourceLength % 16)) % 16);
        ulong finalSize = dataOffset + resourceLength + padding;
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream)) {
            writer.Write(0xF0000011U); writer.Write(1U); writer.Write(1U);
            Zeros(writer, 20); writer.Write(finalSize); writer.Write(0UL); Zeros(writer, 24);
            writer.Write(0U); writer.Write(0U); writer.Write(LuaType);
            writer.Write(1U); writer.Write(0U); writer.Write(16U); writer.Write(16U);
            writer.Write(ResourceHash(name)); writer.Write(LuaType); writer.Write((ulong)dataOffset);
            writer.Write(0UL); writer.Write(0UL); writer.Write(0UL); writer.Write(0UL);
            writer.Write(resourceLength); writer.Write(0U); writer.Write(0U);
            writer.Write(16U); writer.Write(16U); writer.Write(0U);
            Zeros(writer, checked((int)dataOffset - (int)stream.Position));
            writer.Write((uint)body.Length); writer.Write(2U); writer.Write(body); Zeros(writer, (int)padding);
            return stream.ToArray();
        }
    }
}
'@

Add-Type -TypeDefinition $Compiler -Language CSharp

$ConfigPath = Join-Path $ProjectRoot 'hd2runtime.json'
$VersionPath = Join-Path $ProjectRoot 'VERSION'
$SourcePath = Join-Path $ProjectRoot 'src/addon.lua'
$ReadmePath = Join-Path $ProjectRoot 'README.md'
foreach ($Path in @($ConfigPath, $VersionPath, $SourcePath, $ReadmePath)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "missing $Path" }
}

$Config = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json
$Version = (Get-Content -LiteralPath $VersionPath -Raw).Trim()
if ($Config.format -ne 1) { Fail 'unsupported hd2runtime.json format' }
if ($Config.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.name)) { Fail 'name must be a non-empty string' }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail 'VERSION must contain major.minor.patch' }
$Resource = [string]$Config.resource
if ($Resource -notmatch '^mods/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)+$') { Fail 'resource must be mods/author/mod_id using ASCII letters, digits, and underscores' }
if ($Resource -eq $RuntimeModule -or $Resource.StartsWith($RuntimeModule + '/') -or $Resource -eq 'mods/codex/loader') { Fail 'resource identity is reserved' }
if ($Utf8.GetByteCount("-- HD2-Addon: $Resource`n") -gt 256) { Fail 'resource declaration exceeds the Bingus discovery limit' }
if ($Config.requires.bingus.min_release -ne 20 -or $Config.requires.bingus.api -ne 1) { Fail 'requires Bingus release 20+ / API 1' }
if ($Config.requires.hd2runtime.module -ne $RuntimeModule -or $Config.requires.hd2runtime.api -ne 1) { Fail 'requires external HD2Runtime API 1' }
$Minimum = [string]$Config.requires.hd2runtime.min_version
# Optional dependencies never gate loading; HD2Runtime degrades the features that need them.
$Optional = $null
if ($Config.PSObject.Properties.Name -contains 'optional') { $Optional = $Config.optional }
if ($null -ne $Optional) {
    $Names = @($Optional.PSObject.Properties.Name)
    if ($Names.Count -ne 1 -or $Names[0] -ne 'mod_options_menu') { Fail 'only the mod_options_menu optional dependency is supported' }
    $Menu = $Optional.mod_options_menu
    if ($Menu.api -ne 1 -or [int]$Menu.bingus_min_release -lt 18 -or ([string]$Menu.min_version) -notmatch '^\d+\.\d+\.\d+$') {
        Fail 'mod_options_menu needs min_version, api 1 and bingus_min_release 18+'
    }
}
if ($Minimum -notmatch '^\d+\.\d+\.\d+$') { Fail 'HD2Runtime minimum version must contain major.minor.patch' }

$GuidText = [string]$Config.guid
if ($GuidText -eq 'auto') {
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $Digest = $Hasher.ComputeHash($Utf8.GetBytes('hd2runtime-mod:' + $Resource)) }
    finally { $Hasher.Dispose() }
    $GuidBytes = New-Object byte[] 16
    [Array]::Copy($Digest, $GuidBytes, 16)
    $GuidBytes[7] = ($GuidBytes[7] -band 0x0F) -bor 0x50
    $GuidBytes[8] = ($GuidBytes[8] -band 0x3F) -bor 0x80
    $GuidText = (New-Object Guid (,$GuidBytes)).ToString()
} else {
    $ParsedGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($GuidText, [ref]$ParsedGuid) -or $ParsedGuid -eq [Guid]::Empty) { Fail 'guid must be auto or a non-zero UUID' }
    $GuidText = $ParsedGuid.ToString()
}

$Source = [IO.File]::ReadAllText($SourcePath, $Utf8).Replace("`r`n", "`n").Replace("`r", "`n")
$Units = foreach ($Name in @('sample_pickups.lua', 'mission_samples.lua')) {
    $UnitPath = Join-Path (Join-Path $ProjectRoot 'src') $Name
    [IO.File]::ReadAllText($UnitPath, $Utf8).Replace("`r`n", "`n")
}
$Source = ($Units -join "`n") + "`n" + $Source + "`n"
if ($Source.Contains('-- HD2-Addon:') -or $Source.Contains('---@meta')) { Fail 'src/addon.lua must contain gameplay code only, without discovery or SDK-stub declarations' }
if (-not $Source.Contains("require('mods/skyeshade/hd2runtime')") -and -not $Source.Contains('require("mods/skyeshade/hd2runtime")')) {
    Fail "src/addon.lua must require the external HD2Runtime module"
}

$Prefix = @"
-- HD2-Addon: $Resource
local loader=rawget(_G,'CowboyBingusModLoader')
assert(loader and loader.api==1 and type(loader.version)=='number' and loader.version>=16,
    'Requires Bingus Shared Loader API 1 with internal version >=16')
local hd2=require('mods/skyeshade/hd2runtime')
local function semver(v)
    local core,pre=tostring(v):match('^([^%-+]+)%-?([^+]*)')
    local a,b,c=(core or''):match('^(%d+)%.(%d+)%.(%d+)$')
    assert(a,'Invalid HD2Runtime version: '..tostring(v))
    local ids={}
    for id in(pre~=''and pre..'.'or''):gmatch('([^%.]*)%.')do ids[#ids+1]=id end
    return {tonumber(a),tonumber(b),tonumber(c),ids}
end
local function order(p,q)
    local x,y=tonumber(p:match('^%d+$')),tonumber(q:match('^%d+$'))
    if x and y then return x<y and -1 or x>y and 1 or 0 end
    if x then return -1 end
    if y then return 1 end
    return p<q and -1 or p>q and 1 or 0
end
local function at_least(have,need)
    local x,y=semver(have),semver(need)
    for i=1,3 do if x[i]~=y[i]then return x[i]>y[i]end end
    local p,q=x[4],y[4]
    if#p==0 then return true end
    if#q==0 then return false end
    for i=1,math.max(#p,#q)do
        if p[i]==nil then return false end
        if q[i]==nil then return true end
        local o=order(p[i],q[i])
        if o~=0 then return o>0 end
    end
    return true
end
local minimum="$Minimum"
local satisfied=hd2.api_version==1 and at_least(hd2.version,minimum)
if not satisfied and hd2.api_version==1 then
    local compatibility=type(hd2.compatibility)=='table'and hd2.compatibility.require_runtime
    if type(compatibility)=='function'then pcall(compatibility,"$Resource",minimum,"FieldSampleDrops")end
end
assert(satisfied,'HD2Runtime dependency version mismatch')
local key='HD2RuntimeMod:'.."$Resource"
local existing=rawget(_G,key)
if existing then return existing end
local function start()
"@
$Suffix = @"

end
local run=type(hd2.events)=='table' and hd2.events.run_as
local state
if type(run)=='function' then state=run("$Resource",start) else state=start() end
state=state or true
rawset(_G,key,state)
return state
"@
$Body = $Utf8.GetBytes($Prefix.Replace("`r`n", "`n") + "`n" + $Source + $Suffix.Replace("`r`n", "`n"))
$Archive = [HD2StarterArchive]::Build($Resource, $Body)

$Description = "Host corpse sample drops with a configurable 1-300 m radius (30 m by default) for HellForge 25480438. Requires Bingus Shared Loader v20+ and HD2Runtime $Minimum+."
if ($null -ne $Optional) {
    $Description += ' Optional: Mod Options Menu (kill thresholds and radius) and Treasure Map (sample types). Without them the INI and mission difficulty apply.'
}
$Manifest = [ordered]@{
    Version = 1
    Guid = $GuidText
    Name = ([string]$Config.name + ' ' + $Version)
    Description = $Description
    Options = @([ordered]@{ Name = 'FieldSampleDrops'; Description = $Description; Include = @('mod') })
}
$DependencyMetadata = [ordered]@{
    format = 1
    name = [string]$Config.name
    resource = $Resource
    guid = $GuidText
    requires = $Config.requires
}
if ($null -ne $Optional) { $DependencyMetadata['optional'] = $Optional }
$Report = [ordered]@{
    resource = $Resource
    runtime_bundled = $false
    sdk_stubs_bundled = $false
    requires = $Config.requires
    optional = $Optional
    builder = 'Windows PowerShell/.NET; Python not required'
    deployed = $false
    game_launched = $false
}

$SafeName = (([string]$Config.name -replace '[^A-Za-z0-9._-]+', '-')).Trim('-')
if ([string]::IsNullOrWhiteSpace($SafeName)) { $SafeName = 'HD2Mod' }
$BuildDirectory = Join-Path $ProjectRoot 'build'
[IO.Directory]::CreateDirectory($BuildDirectory) | Out-Null
$Output = Join-Path $BuildDirectory ($SafeName + '-' + $Version + '.zip')

Add-Type -AssemblyName System.IO.Compression
$File = [IO.File]::Open($Output, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $Zip = New-Object IO.Compression.ZipArchive($File, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        function Add-ZipBytes([string] $Name, [byte[]] $Bytes) {
            $Entry = $Zip.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal)
            $Stream = $Entry.Open()
            try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
        }
        Add-ZipBytes 'manifest.json' (JsonBytes $Manifest)
        Add-ZipBytes 'hd2runtime.json' (JsonBytes $DependencyMetadata)
        Add-ZipBytes 'build-report.json' (JsonBytes $Report)
        Add-ZipBytes 'README.md' ([IO.File]::ReadAllBytes($ReadmePath))
        Add-ZipBytes ('mod/' + $ArchiveName) $Archive
        Add-ZipBytes ('mod/' + $ArchiveName + '.stream') ([byte[]]@())
        Add-ZipBytes ('mod/' + $ArchiveName + '.gpu_resources') ([byte[]]@())
    } finally { $Zip.Dispose() }
} finally { $File.Dispose() }

Write-Host "Built $Output"
Write-Host "Gameplay resource: $Resource"
Write-Host 'HD2Runtime implementation bundled: false'
Write-Host 'SDK stubs bundled: false'
