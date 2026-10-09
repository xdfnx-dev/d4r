# Regression for Steam/launcher processes that do not inherit D4R_* variables.
# Uses real player-mode DLLs and OptiScaler; no game or GPU kernel is launched.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GamePackageRoot,
    [Parameter(Mandatory=$true)][string]$ShimDll,
    [Parameter(Mandatory=$true)][string]$LoaderDll,
    [Parameter(Mandatory=$true)][string]$OptiScalerDll,
    [Parameter(Mandatory=$true)][string]$NgxCore,
    [Parameter(Mandatory=$true)][string]$DlssDll,
    [string]$CompilerRoot, [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'gpu-target.ps1')
foreach ($name in @('GamePackageRoot','ShimDll','LoaderDll','OptiScalerDll','NgxCore','DlssDll')) {
    Set-Variable -Name $name -Value ((Get-Item -LiteralPath (Get-Variable -Name $name -ValueOnly)).FullName)
}
$arch=Get-D4RGpuTarget $GamePackageRoot
if (!$CompilerRoot) { $CompilerRoot=Join-Path $repo '.tools/llvm-mingw-20260922-ucrt-x86_64' }
if (!$OutputDirectory) { $OutputDirectory=Join-Path $repo ('test-results/player-feature-discovery/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('d4r-player-discovery-'+[Guid]::NewGuid().ToString('N'))
$bridge=Join-Path $fixture 'd4r'
$results=@()
function Stage([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Force (Split-Path $Destination) | Out-Null
    # Hard links keep the private fixture small. Inputs are never modified.
    try { New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null }
    catch { Copy-Item -LiteralPath $Source -Destination $Destination }
}
function Build([string]$Source,[string]$Name) {
    $compiler=Join-Path $CompilerRoot 'bin/x86_64-w64-mingw32-clang++.exe'
    $executable=Join-Path $fixture ($Name+'.exe')
    $ErrorActionPreference='Continue'
    & $compiler -std=c++17 -O1 -static -municode $Source -o $executable -ldxgi *> (Join-Path $OutputDirectory ($Name+'-build.log'))
    if ($LASTEXITCODE) { throw "Build failed: $Name" }
    return $executable
}
function Run([string]$Exe,[string]$Argument,[string]$Name,[string]$Report='') {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Exe; $info.WorkingDirectory=$fixture
    if ($Argument.Contains('"')) { throw 'Unsupported quote in DLL path.' }
    $info.Arguments='"'+$Argument+'"'; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    if ($Report) {
        if ($Report.Contains('"')) { throw 'Unsupported quote in report path.' }
        $info.Arguments+=' "'+$Report+'"'
    }
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('D4R_') -or $key.StartsWith('ZLUDA_') -or $key.StartsWith('HSA_OVERRIDE_') -or $key -eq 'HIP_PATH') {
            $info.EnvironmentVariables.Remove($key)
        }
    }
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try {
        [void]$process.Start(); $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw "$Name timed out." }
        $log=$stdout.GetAwaiter().GetResult(); $errorLog=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($Name+'-stdout.log')),$log)
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($Name+'-stderr.log')),$errorLog)
        foreach ($file in @(@{source=(Join-Path $bridge 'd4r_nvngx.log'); name=($Name+'-backend.log')},
                            @{source=(Join-Path $fixture 'OptiScaler.log'); name=($Name+'-frontend.log')})) {
            if (Test-Path -LiteralPath $file.source) { Copy-Item -LiteralPath $file.source -Destination (Join-Path $OutputDirectory $file.name) }
        }
        if ($process.ExitCode) { throw "$Name failed with exit $($process.ExitCode); see $OutputDirectory" }
        return $log
    } finally { $process.Dispose() }
}
try {
    New-Item -ItemType Directory -Force $bridge | Out-Null
    foreach ($tree in @('hip','zluda')) {
        $source=Join-Path $GamePackageRoot "d4r/$tree"
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            Stage $file.FullName (Join-Path $bridge ("$tree/"+$file.FullName.Substring($source.Length+1)))
        }
    }
    $native=Join-Path $GamePackageRoot 'd4r/native'
    foreach ($file in Get-ChildItem -LiteralPath $native -File) { Stage $file.FullName (Join-Path $bridge "native/$arch/$($file.Name)") }
    Stage $ShimDll (Join-Path $bridge "_nvngx_$arch.dll")
    Stage $LoaderDll (Join-Path $bridge '_nvngx.dll')
    Stage $OptiScalerDll (Join-Path $fixture 'OptiScaler.dll')
    Stage $NgxCore (Join-Path $bridge 'ngx/_nvngx.dll')
    Stage $DlssDll (Join-Path $bridge 'nvngx_dlss.dll')
    Stage (Join-Path $GamePackageRoot "d4r/pixel_convert_$arch.hsaco") (Join-Path $bridge "pixel_convert_$arch.hsaco")
    Stage (Join-Path $repo 'tools/windows/dll-pins.txt') (Join-Path $bridge 'dll-pins.txt')
    "[DLSS]`nModel=K`n[Debug]`nLog=verbose`n[Paths]`nCacheDir=$fixture/cache" |
        Set-Content -LiteralPath (Join-Path $bridge 'd4r.ini') -Encoding ASCII
    "[DLSS]`nEnabled=true`nAllowExternalBackend=true`n[Libraries]`nNvngxPath=$bridge`nNvngxDlssPath=$bridge`nNvngxFeaturePath=$bridge`n[Log]`nLogToFile=true`nLogLevel=0`n[Menu]`nDisableSplash=true" |
        Set-Content -LiteralPath (Join-Path $fixture 'OptiScaler.ini') -Encoding ASCII
    $direct=Build (Join-Path $repo 'tools/windows/loader_selection_probe.cpp') 'loader-discovery'
    $frontend=Build (Join-Path $repo 'tools/windows/frontend_discovery_probe.cpp') 'frontend-discovery'
    $adapterReport=Join-Path $OutputDirectory 'direct-adapters.log'
    [void](Run $direct (Join-Path $bridge '_nvngx.dll') 'direct' $adapterReport)
    $log=Get-Content -LiteralPath $adapterReport -Raw
    $backend=Get-Content -LiteralPath (Join-Path $OutputDirectory 'direct-backend.log') -Raw
    if (($log+$backend) -notmatch 'vendor=0x1002 status=0x1 supported=0' -or
        $log -notmatch 'vendor=0x1414 status=0x1 supported=4' -or
        $backend -notmatch 'd4r: player mode' -or $backend -match 'FAILURE|DLSS disabled') { throw 'Environment-free loader did not report supported AMD hardware.' }
    $results+=@{case='loader-without-launcher-environment'; passed=$true; architecture=$arch; gpuKernelsExecuted=$false}
    [void](Run $frontend (Join-Path $fixture 'OptiScaler.dll') 'frontend')
    $backend=Get-Content -LiteralPath (Join-Path $OutputDirectory 'frontend-backend.log') -Raw
    $opti=Get-Content -LiteralPath (Join-Path $OutputDirectory 'frontend-frontend.log') -Raw
    if ($opti -notmatch 'External D3D12 DLSS backend: .+ support=true result=1' -or
        $backend -notmatch 'd4r: player mode' -or $backend -match 'FAILURE|DLSS disabled') { throw 'OptiScaler did not discover supported AMD hardware without launcher environment.' }
    $results+=@{case='optiscaler-without-launcher-environment'; passed=$true; architecture=$arch; gpuKernelsExecuted=$false}
    Write-Host "PASS PLAYER_FEATURE_DISCOVERY cases=$($results.Count) Report: $OutputDirectory"
} finally {
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
    # This literal target is our unique private temporary fixture, not an input.
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (!$resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^d4r-player-discovery-[0-9a-f]{32}$') { throw 'Unexpected private fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
