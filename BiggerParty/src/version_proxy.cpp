// BiggerParty — native patcher for Solasta II (Brimstone-Win64-Shipping.exe), built as a version.dll proxy.
//
// The game hard-codes the party size in four places; this DLL flips those literals in memory at start-up
// (and on config change) to the configured PartySize. Nothing on disk is modified. Every site is located by
// byte signature and must match exactly once, otherwise the patch is refused — after a game update the mod
// simply goes inert and says so in BiggerParty.log.
//
//   1. UGameSessionViewModel::SetupDefaultSession           mov r13d, 4          -> character slots per session
//   2. UBrimstoneCommonSessionSubsystem::CreateOnlineHostSessionRequest   MaxPlayerCount = 4 -> lobby size
//   3+4. UGameSessionViewModel::ReadRuntimeSessionFromGameState  lea r12d,[rbx+4] / cmp ebx,4 -> player-slot cap
//        when a saved game is (re)hosted (the blank character slots it also creates are discarded by the
//        same function once the saved party is read, so 4-hero saves are unaffected)
//
// Config: BiggerParty.ini next to this DLL ([BiggerParty] Enabled=1 PartySize=6). A watcher thread re-reads it
// when it changes, so the in-game toggle (handled by the Lua half) applies without a restart.
//
// Signatures verified against build CL-112340 (2026-09-10).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// ------------------------------------------------------------------------------------------------
// Logging + config
// ------------------------------------------------------------------------------------------------
static wchar_t g_dir[MAX_PATH];        // directory this DLL lives in (Brimstone\Binaries\Win64)
static wchar_t g_logPath[MAX_PATH];
static wchar_t g_iniPath[MAX_PATH];

static void Log(const char* fmt, ...)
{
    FILE* f = nullptr;
    if (_wfopen_s(&f, g_logPath, L"a") != 0 || !f) return;
    SYSTEMTIME st; GetLocalTime(&st);
    fprintf(f, "[%02d:%02d:%02d] ", st.wHour, st.wMinute, st.wSecond);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

struct Config { bool enabled = true; int partySize = 6; int maxPlayers = 0; };   // maxPlayers 0 = follow partySize

static Config ReadConfig()
{
    Config c;
    FILE* f = nullptr;
    if (_wfopen_s(&f, g_iniPath, L"r") != 0 || !f) { Log("config: %ls not found, using defaults (Enabled=1, PartySize=6)", g_iniPath); return c; }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') ++p;
        if (*p == ';' || *p == '#' || *p == '[' || *p == '\n' || *p == 0) continue;
        char key[64] = {0}; int val = 0;
        if (sscanf_s(p, "%63[^= \t] = %d", key, (unsigned)sizeof key, &val) == 2 || sscanf_s(p, "%63[^=]=%d", key, (unsigned)sizeof key, &val) == 2) {
            if (_stricmp(key, "Enabled") == 0) c.enabled = val != 0;
            else if (_stricmp(key, "PartySize") == 0) c.partySize = val;
            else if (_stricmp(key, "MaxPlayers") == 0) c.maxPlayers = val;
        }
    }
    fclose(f);
    if (c.partySize < 1) c.partySize = 1;
    if (c.partySize > 8) c.partySize = 8;      // the creation screen and lobby UI were not designed for more
    if (c.maxPlayers <= 0) c.maxPlayers = c.partySize;
    if (c.maxPlayers < 1) c.maxPlayers = 1;
    if (c.maxPlayers > c.partySize) c.maxPlayers = c.partySize;
    return c;
}

// ------------------------------------------------------------------------------------------------
// Signature patches
// ------------------------------------------------------------------------------------------------
struct Patch {
    const char* name;
    bool playerSlots;          // true = governed by MaxPlayers, false = by PartySize
    std::vector<int> sig;      // -1 = wildcard
    size_t offset;             // byte within the signature that holds the literal
    uint8_t original;          // expected literal
    uint8_t* address = nullptr;
    bool applied = false;
};

static std::vector<Patch> g_patches = {
    { "SetupDefaultSession slot count", false,
      { 0x41, 0xBD, 0x04, 0x00, 0x00, 0x00, 0x89, 0x44, 0x24, 0x5C, 0x48, 0x8D, 0x05 }, 2, 4 },
    { "CreateOnlineHostSessionRequest MaxPlayerCount", true,
      { 0xC7, 0x80, 0xA0, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xC6, 0x40, 0x2A, 0x01 }, 6, 4 },
    { "ReadRuntimeSessionFromGameState slot cap (lea)", true,
      { 0x44, 0x8D, 0x63, 0x04, 0x39, 0x9F, 0xC0, 0x00, 0x00, 0x00, 0x0F, 0x85 }, 3, 4 },
    { "ReadRuntimeSessionFromGameState slot cap (cmp)", true,
      { 0x83, 0xFB, 0x04, 0x48, 0x8B, 0xCF, 0x44, 0x0F, 0x4C, 0xE3 }, 2, 4 },
};

static bool GetTextSection(uint8_t*& start, size_t& size)
{
    auto base = (uint8_t*)GetModuleHandleW(nullptr);
    if (!base) return false;
    auto dos = (IMAGE_DOS_HEADER*)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto nt = (IMAGE_NT_HEADERS64*)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
    auto sec = IMAGE_FIRST_SECTION(nt);
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        if (memcmp(sec->Name, ".text", 5) == 0) {
            start = base + sec->VirtualAddress;
            size = sec->Misc.VirtualSize;
            return true;
        }
    }
    return false;
}

static void LocatePatches()
{
    uint8_t* text; size_t size;
    if (!GetTextSection(text, size)) { Log("could not find .text section"); return; }
    Log("scanning .text (%zu bytes) for %zu signatures", size, g_patches.size());
    for (auto& p : g_patches) {
        const size_t n = p.sig.size();
        const uint8_t first = (uint8_t)p.sig[0];
        size_t hits = 0; uint8_t* found = nullptr;
        for (uint8_t* cur = text; cur + n <= text + size; ) {
            cur = (uint8_t*)memchr(cur, first, (text + size) - cur - n + 1);
            if (!cur) break;
            bool ok = true;
            for (size_t k = 1; k < n; ++k) {
                if (p.sig[k] >= 0 && cur[k] != (uint8_t)p.sig[k]) { ok = false; break; }
            }
            if (ok) { ++hits; found = cur; }
            ++cur;
        }
        if (hits == 1 && found[p.offset] == p.original) {
            p.address = found + p.offset;
            Log("  %-48s at %p (RVA 0x%llX)", p.name, p.address, (unsigned long long)(p.address - (uint8_t*)GetModuleHandleW(nullptr)));
        } else {
            Log("  %-48s NOT patchable: %zu match(es)%s — game build changed?", p.name, hits, hits == 1 ? ", literal differs" : "");
        }
    }
}

static bool WriteByte(uint8_t* addr, uint8_t value)
{
    DWORD old = 0;
    if (!VirtualProtect(addr, 1, PAGE_EXECUTE_READWRITE, &old)) return false;
    *addr = value;
    DWORD tmp = 0;
    VirtualProtect(addr, 1, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), addr, 1);
    return true;
}

static void ApplyConfig(const Config& c)
{
    for (auto& p : g_patches) {
        if (!p.address) continue;
        const int target = p.playerSlots ? c.maxPlayers : c.partySize;
        const bool want = c.enabled && target != p.original;
        const uint8_t value = (uint8_t)target;
        if (want) {
            if (WriteByte(p.address, value)) { p.applied = true; Log("  patched  %-48s -> %d", p.name, value); }
            else Log("  FAILED to write %s", p.name);
        } else if (p.applied || *p.address != p.original) {
            if (WriteByte(p.address, p.original)) { p.applied = false; Log("  restored %-48s -> %d", p.name, p.original); }
        }
    }
    Log("state: %s (PartySize=%d, MaxPlayers=%d)", c.enabled ? "ACTIVE" : "inert (vanilla)", c.partySize, c.maxPlayers);
}

// ------------------------------------------------------------------------------------------------
// Config watcher: re-apply when BiggerParty.ini changes (the Lua side toggles it from a hotkey)
// ------------------------------------------------------------------------------------------------
static FILETIME g_lastWrite = {};

static bool IniChanged()
{
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(g_iniPath, GetFileExInfoStandard, &fad)) return false;
    if (CompareFileTime(&fad.ftLastWriteTime, &g_lastWrite) != 0) { g_lastWrite = fad.ftLastWriteTime; return true; }
    return false;
}

static DWORD WINAPI WatcherThread(LPVOID)
{
    IniChanged();   // prime
    for (;;) {
        Sleep(1000);
        if (IniChanged()) {
            Config c = ReadConfig();
            Log("config changed: Enabled=%d PartySize=%d MaxPlayers=%d", c.enabled ? 1 : 0, c.partySize, c.maxPlayers);
            ApplyConfig(c);
        }
    }
}

// ------------------------------------------------------------------------------------------------
// version.dll forwarding
// ------------------------------------------------------------------------------------------------
static HMODULE g_real = nullptr;
static FARPROC Real(const char* name)
{
    if (!g_real) {
        wchar_t path[MAX_PATH];
        GetSystemDirectoryW(path, MAX_PATH);
        wcscat_s(path, L"\\version.dll");
        g_real = LoadLibraryW(path);
    }
    return g_real ? GetProcAddress(g_real, name) : nullptr;
}

// Internal names avoid clashing with the SDK's own prototypes; the linker directive exports each one
// under the real API name so the game's import table resolves against this DLL.
#define FWD(ret, name, params, args)                                                  extern "C" ret WINAPI Fwd_##name params {                                             typedef ret (WINAPI *Fn) params;                                                  static Fn fn = (Fn)Real(#name);                                                   return fn ? fn args : (ret)0;                                                 }                                                                                 __pragma(comment(linker, "/export:" #name "=Fwd_" #name))

FWD(BOOL,  GetFileVersionInfoA,       (LPCSTR a, DWORD b, DWORD c, LPVOID d), (a, b, c, d))
FWD(BOOL,  GetFileVersionInfoW,       (LPCWSTR a, DWORD b, DWORD c, LPVOID d), (a, b, c, d))
FWD(BOOL,  GetFileVersionInfoExA,     (DWORD a, LPCSTR b, DWORD c, DWORD d, LPVOID e), (a, b, c, d, e))
FWD(BOOL,  GetFileVersionInfoExW,     (DWORD a, LPCWSTR b, DWORD c, DWORD d, LPVOID e), (a, b, c, d, e))
FWD(DWORD, GetFileVersionInfoSizeA,   (LPCSTR a, LPDWORD b), (a, b))
FWD(DWORD, GetFileVersionInfoSizeW,   (LPCWSTR a, LPDWORD b), (a, b))
FWD(DWORD, GetFileVersionInfoSizeExA, (DWORD a, LPCSTR b, LPDWORD c), (a, b, c))
FWD(DWORD, GetFileVersionInfoSizeExW, (DWORD a, LPCWSTR b, LPDWORD c), (a, b, c))
FWD(BOOL,  GetFileVersionInfoByHandle,(DWORD a, HANDLE b, LPVOID c, DWORD d, LPVOID e), (a, b, c, d, e))
FWD(BOOL,  VerQueryValueA,            (LPCVOID a, LPCSTR b, LPVOID* c, PUINT d), (a, b, c, d))
FWD(BOOL,  VerQueryValueW,            (LPCVOID a, LPCWSTR b, LPVOID* c, PUINT d), (a, b, c, d))
FWD(DWORD, VerFindFileA,              (DWORD a, LPCSTR b, LPCSTR c, LPCSTR d, LPSTR e, PUINT f, LPSTR g, PUINT h), (a, b, c, d, e, f, g, h))
FWD(DWORD, VerFindFileW,              (DWORD a, LPCWSTR b, LPCWSTR c, LPCWSTR d, LPWSTR e, PUINT f, LPWSTR g, PUINT h), (a, b, c, d, e, f, g, h))
FWD(DWORD, VerInstallFileA,           (DWORD a, LPCSTR b, LPCSTR c, LPCSTR d, LPCSTR e, LPCSTR f, LPSTR g, PUINT h), (a, b, c, d, e, f, g, h))
FWD(DWORD, VerInstallFileW,           (DWORD a, LPCWSTR b, LPCWSTR c, LPCWSTR d, LPCWSTR e, LPCWSTR f, LPWSTR g, PUINT h), (a, b, c, d, e, f, g, h))
FWD(DWORD, VerLanguageNameA,          (DWORD a, LPSTR b, DWORD c), (a, b, c))
FWD(DWORD, VerLanguageNameW,          (DWORD a, LPWSTR b, DWORD c), (a, b, c))

// ------------------------------------------------------------------------------------------------
BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        GetModuleFileNameW(inst, g_dir, MAX_PATH);
        if (wchar_t* slash = wcsrchr(g_dir, L'\\')) *slash = 0;
        swprintf_s(g_logPath, L"%s\\BiggerParty.log", g_dir);
        swprintf_s(g_iniPath, L"%s\\BiggerParty.ini", g_dir);
        DeleteFileW(g_logPath);

        wchar_t exe[MAX_PATH]; GetModuleFileNameW(nullptr, exe, MAX_PATH);
        Log("BiggerParty patcher loaded into %ls", exe);
        Config c = ReadConfig();
        Log("config: Enabled=%d PartySize=%d MaxPlayers=%d", c.enabled ? 1 : 0, c.partySize, c.maxPlayers);
        LocatePatches();
        ApplyConfig(c);
        CreateThread(nullptr, 0, WatcherThread, nullptr, 0, nullptr);
    }
    return TRUE;
}
