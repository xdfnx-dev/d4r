// Exercise OptiScaler-owned backend discovery without initializing NGX,
// allocating GPU memory, or launching a game.
#include <windows.h>
#include <dxgi1_6.h>
#include <cstdio>

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: frontend_discovery_probe OPTISCALER_DLL\n");
        return 2;
    }
    if (!LoadLibraryW(argv[1])) {
        std::fprintf(stderr, "FRONTEND_LOAD_FAILED error=%lu\n", GetLastError());
        return 3;
    }
    IDXGIFactory4* factory = nullptr;
    const HRESULT result = CreateDXGIFactory2(0, __uuidof(IDXGIFactory4), reinterpret_cast<void**>(&factory));
    if (FAILED(result)) {
        std::fprintf(stderr, "FACTORY_FAILED result=0x%lx\n", static_cast<unsigned long>(result));
        return 4;
    }
    IDXGIAdapter1* adapter = nullptr;
    HRESULT enumeration = S_OK;
    for (UINT i = 0; (enumeration = factory->EnumAdapters1(i, &adapter)) == S_OK; ++i) {
        DXGI_ADAPTER_DESC1 desc{};
        const HRESULT description = adapter->GetDesc1(&desc);
        adapter->Release();
        if (FAILED(description)) { factory->Release(); return 4; }
        std::printf("FRONTEND_ADAPTER index=%u vendor=0x%04x luid=%08lx:%08lx name=%ls\n",
            i, desc.VendorId, static_cast<unsigned long>(desc.AdapterLuid.HighPart),
            static_cast<unsigned long>(desc.AdapterLuid.LowPart), desc.Description);
    }
    factory->Release();
    if (enumeration != DXGI_ERROR_NOT_FOUND) return 4;
    std::printf("FRONTEND_DISCOVERY pid=%lu enumeration_completed=1\n", GetCurrentProcessId());
    // The script separately checks the backend support result in OptiScaler.log.
    return 0;
}
