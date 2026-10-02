# d4r for Windows / RDNA3 and RDNA4

A Windows fork of [countervolts/d4r](https://github.com/countervolts/d4r) that
runs DLSS Super Resolution on AMD GPUs through
D3D12, OptiScaler, ZLUDA and HIP. The target models are **DLSS 4 preset K**
and **DLSS 4.5 preset M**. The runtime runs directly on Windows 11.

**Status: development / prerelease.** K and M run on the tested RX 9070 XT,
including 4K in Silent Hill 2. Improving K performance is the current priority.
Experimental builds cover RDNA3 `gfx1100..gfx1103`, RDNA3.5 `gfx1150..gfx1154`
and RDNA4 `gfx1200/gfx1201`. Only RX 9070 XT has physical validation here;
all other targets are compile-tested and their K/M/interop remain unverified.
The quick-test ZIP selects the actual GPU target automatically. Developer
packages remain target-specific. See
[GPU coverage and build commands](docs/windows-gpu-support.md).

## Download and run

For the shortest test, download **d4r-windows-quick-test.zip** from the
[latest prereleases](https://github.com/xdfnx-dev/d4r/releases), extract the
whole ZIP and double-click **START-K.cmd**. File pickers ask for the game EXE
and your two original NVIDIA DLLs once. **START-M.cmd** tests M and
**RESTORE-GAME.cmd** restores the original game files. Send the single ZIP
printed after exiting the game, plus GPU/game/preset and the visual result.
The isolated HIP runtime is included; no SDK install or source editing is
needed. Read the [short instructions](docs/windows-quick-test.txt).
This diagnostic uses conservative synchronous interop and output checks;
it launches without an attached debugger and logs process exit codes. It is
not an FPS benchmark. Corresponding sources are a separate
release download, unnecessary for testing.

The commands below apply to the separate developer packages.

[Prebuilt releases](https://github.com/xdfnx-dev/d4r/releases) include the
Windows shim, patched ZLUDA, isolated HIP runtime, patched OptiScaler,
11 native K kernels, 5 native M kernels and the corresponding committed sources.

You need Windows 11 x64, a GPU reporting one of the listed HIP targets and
a D3D12 game without anti-cheat. RX 9070 XT is the validated configuration.
The tested AMD driver is `32.0.31041.1004`. Other GPUs and drivers have not
received the same validation.
Choose the archive for your actual target: RX 9060/9060 XT requires gfx1200;
RX 9070/9070 XT/9070 GRE requires gfx1201. Older prereleases were gfx1201-only.
The installer inventories HIP before changing game files, rejects mismatched
packages and local vkd3d/Wine D3D12 proxies, and prints one diagnostic ZIP
on failure. Unvalidated GPUs require a compatible Windows driver/HIP runtime;
compilation alone does not establish that support.

Supply your own local `_nvngx.dll` and `nvngx_dlss.dll`. The tested pair is
NGX `32.0.16.1714` and DLSS `310.9.1.0`. The native manifest checks the
DLSS DLL's SHA256. NVIDIA binaries are excluded from the release.

Extract the ZIP and run this command from its directory, replacing the paths
with your game and local DLL locations:

```powershell
.\windows-game.ps1 -GameExe "D:\Games\SILENT HILL 2\SHProto\Binaries\Win64\SHProto-Win64-Shipping.exe" -NgxCore "C:\Users\Administrator\d4r\_nvngx.dll" -DlssDll "C:\Users\Administrator\d4r\nvngx_dlss.dll" -Preset 11 -AsyncInterop
```

Select an upscaler intercepted by OptiScaler in the game. `-Preset 11` selects
K; `-Preset 13` selects M. Start M testing without `-AsyncInterop`: the async
path is currently being tested primarily with K. The first launch may take
time to compile PTX; subsequent launches reuse the cache.

For an untested target, begin without `-AsyncInterop` and add `-ValidateOutput`.
`-CaptureExceptions` attaches a debugger; use it only for an explicit developer
diagnostic when the game allows debugging. The script installs `dxgi.dll`, an OptiScaler configuration and a `d4r`
directory beside the game EXE, backing up replaced files first. The current
frame's inputs and output stay in VRAM. Restore the original files with:

```powershell
.\windows-game.ps1 -Action restore -GameExe "D:\Games\SILENT HILL 2\SHProto\Binaries\Win64\SHProto-Win64-Shipping.exe"
```

See [docs/windows-game.md](docs/windows-game.md) for installation options,
DLL requirements and restoration details.

## Validation

| Check | Result on RX 9070 XT |
| --- | --- |
| GPU detection | HIP automatically detects `gfx1201`; D3D12/HIP LUID is checked |
| HIP and CUDA through ZLUDA | Native HIP kernel and CUDA Driver API / PTX tests pass |
| D3D12 ↔ HIP | Shared VRAM buffers and fences; import/release lifetime test passes |
| K transformer | All 11 native layers, NumPy/PTX/replay validation |
| M transformer | All 5 native layers, 40 temporal captures, exact baseline |
| Async K | Queued frames and Release/CreateFeature match synchronous RGB exactly |
| Silent Hill 2 / K / 4K | 16,941 frames checked for NaN/Inf, 203,292 native launches, 0 backend errors |
| Windows hardware/software tests | All 20 CTest gates pass on the RX 9070 XT |
| Experimental GPU builds | All 11 targets compile, 209 device objects have correct ELF targets; other GPUs unverified |
| Package preflight | Wrong target and vkd3d rejected before game changes; isolated install/restore passes |

Exact comparisons refer to this project's validated reference/control
implementations. Comparison with DLSS on a physical RTX has not been performed.
Testing one game does not establish compatibility with every D3D12 game.

## Performance and limitations

The latest 30-second capture of the local 4K scene records **65.250 FPS**.
AMD ADLX reports **93.500% mean GPU utilization**, rather than the earlier
63% Task Manager reading. This run uses async interop, batched GPU inputs and
locally built and validated K output-store kernels, with detailed profiling off.
Those objects contain NVIDIA-derived code and are excluded from the public ZIP.
Local build and validation commands are in
[docs/windows-performance.md](docs/windows-performance.md).

Shared V tiles now reduce enc0's isolated replay time by about 5%, with exact
outputs; this does not mean 5% game FPS. This capture includes that enc0 and
private WGP output kernels. The preceding scene capture was 64.661 FPS;
the small single comparison does not establish a reproducible gain. WGP
remains an optional experiment. Its ten-minute game check completes 35,664
frames with zero backend errors, CPU image copies or previous-frame outputs;
output scans are disabled in that performance run.
K performance remains under development. The capture is not a controlled
FSR4 comparison. `-AsyncInterop` is opt-in and requires one D3D12 command queue.
Feature release and resource reconfiguration wait for GPU consumers to finish;
ordinary frame submission does not hold the CUDA mutex.

M uses the validated FP16-equivalent baseline. Native RDNA4 FP8 is separately
validated but has not demonstrated a full-network speedup and is disabled by
default. Windows preset L is not validated. Frame Generation and DLSS 5 are
outside the current scope.

The package uses TheRock `10.2.0a20260929` / HIP `7.17.26386`. Stable HIP 7.2
reproduces a mapped external-memory release leak, so the validated package
pins a separate TheRock runtime. GPU architecture is never overridden.

## Build from source

```powershell
git clone https://github.com/xdfnx-dev/d4r.git
cd d4r
```

Pinned toolchain and source-patch setup is documented in
[docs/windows-rdna4-port.md](docs/windows-rdna4-port.md). You need CMake + Ninja,
LLVM/MinGW, a Rust GNU toolchain, TheRock HIP and, for OptiScaler, MSVC v143
and the Windows SDK. Setup scripts use `.tools`; source dependencies use `external`.

After preparing the dependencies, run from the repository root:

```powershell
.\scripts\windows\build-zluda-windows.ps1
.\scripts\windows\build-windows-rdna4.ps1 -RuntimeProfile therock -ZludaRoot "$PWD\dist\zluda-windows-final" -InstallDirectory "$PWD\dist\windows-rdna4-command-list"
.\scripts\windows\stage-native-k.ps1 -DlssDll "$PWD\nvngx_dlss.dll" -PackageRoot "$PWD\dist\windows-rdna4-command-list"
.\scripts\windows\stage-native-m.ps1 -DlssDll "$PWD\nvngx_dlss.dll" -PackageRoot "$PWD\dist\windows-rdna4-command-list"
.\scripts\windows\build-optiscaler-windows.ps1
.\scripts\windows\package-windows-game.ps1 -ArchivePath "$PWD\dist\windows-rdna4-game.zip"
```

Creating a distributable ZIP requires committed source. The package includes
a hash manifest, dependency licenses, source patches and a snapshot of that commit.
`-GpuArch gfx1101` selects a target such as RX 7800 XT; CMake accepts
`-DD4R_GPU_ARCH=gfx1101`. `build-windows-gpu-matrix.ps1` builds all eleven
targets without running GPU workloads. Staging/installation reject mixed
objects. gfx11 uses its native WMMA layout and a Windows LDS lane exchange
adapted from realdody's correction; gfx1201 instructions remain unchanged.

## Tests and diagnostics

After building, run the hardware gates:

```powershell
& .\.tools\python\cmake\data\bin\ctest.exe --test-dir build/windows-rdna4-therock --output-on-failure
```

Run the async K regression with your local NVIDIA DLLs at the repository root:

```powershell
.\scripts\windows\test-async-k.ps1 -ZludaRoot "$PWD\dist\zluda-windows-final"
```

Success requires `PASS`, exact RGB, finite output and `passed: true` in
`validation.json`. For a bounded game test, add `-RunSeconds 120 -ValidateOutput`
to the launch command. The script saves one ZIP containing stdout/stderr,
runtime/driver information, native/translated kernel records and OptiScaler logs.
Use `-CaptureExceptions` when investigating a crash.

`-ProfileStages` measures host stages; `-ProfileCudaApi` measures existing CUDA
API waits; `-ProfileGpuBoundary` with `-AsyncInterop` measures D3D12 GPU intervals
around interop. `-ProfileKernels` synchronizes HIP events and changes scheduling.
Leave profiling and output scans disabled when measuring ordinary FPS.

## Documentation and licenses

- [Architecture, dependencies, milestones and results](docs/windows-rdna4-port.md).
- [Game installation and restoration](docs/windows-game.md).
- [K/M and FP8 measurements](docs/windows-performance.md).
- [OptiScaler source patches](patches/optiscaler/README.md).
- [ZLUDA source patches](patches/zluda).

This project builds on countervolts' work; Linux upstream code and documentation
are retained for compatibility. The fork is not affiliated with NVIDIA or AMD.
d4r's license is in [LICENSE](LICENSE); dependency licenses are included in the package.
