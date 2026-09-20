// BiggerParty installer for Solasta II — self-contained console installer.
//
// Carries UE4SS (experimental build for UE 5.6), the BiggerParty mod (version.dll patcher + Lua) and the
// optional GiveSpellbook and Narrator mods as embedded resources. Finds the game through Steam, checks
// that the game build still has the four patch sites, installs / updates / uninstalls, and edits UE4SS's
// mod list.
//
// Usage: double-click. Command line: BiggerParty-Installer.exe [/install|/uninstall] [/spellbook] [/narrator] [/game "<Solasta 2 folder>"] [/silent]

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <io.h>
#include <fcntl.h>
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include "payload_index.h"

#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")

static const wchar_t* kVersion = L"BiggerParty 1.4.6 (game builds CL-112340 / CL-112436)";
static bool g_silent = false;

// ------------------------------------------------------------------------------------------------
static void Say(const wchar_t* fmt, ...) { va_list ap; va_start(ap, fmt); vwprintf(fmt, ap); va_end(ap); wprintf(L"\n"); }
static bool Ask(const wchar_t* question, bool def)
{
    if (g_silent) return def;
    wprintf(L"%s [%s] ", question, def ? L"Y/n" : L"y/N");
    wchar_t buf[16] = {0};
    if (!fgetws(buf, 16, stdin)) return def;
    if (buf[0] == L'\n' || buf[0] == 0) return def;
    return buf[0] == L'y' || buf[0] == L'Y';
}
static void Pause() { if (g_silent) return; wprintf(L"\nPress Enter to close."); wchar_t b[8]; fgetws(b, 8, stdin); }

static bool Exists(const std::wstring& p) { return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; }
static bool IsDir(const std::wstring& p) { DWORD a = GetFileAttributesW(p.c_str()); return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY); }
static std::wstring Join(const std::wstring& a, const std::wstring& b) { return a + (a.empty() || a.back() == L'\\' ? L"" : L"\\") + b; }

static bool MakeDirs(const std::wstring& dir)
{
    if (dir.empty() || IsDir(dir)) return true;
    size_t pos = dir.find_last_of(L'\\');
    if (pos != std::wstring::npos && pos > 2) MakeDirs(dir.substr(0, pos));
    return CreateDirectoryW(dir.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

static std::vector<uint8_t> ReadAll(const std::wstring& p)
{
    std::vector<uint8_t> out;
    HANDLE h = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return out;
    LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
    out.resize((size_t)sz.QuadPart);
    DWORD rd = 0; size_t off = 0;
    while (off < out.size() && ReadFile(h, out.data() + off, (DWORD)min((size_t)1 << 26, out.size() - off), &rd, nullptr) && rd) off += rd;
    CloseHandle(h);
    return out;
}
static bool WriteFileBytes(const std::wstring& p, const void* data, size_t n)
{
    size_t pos = p.find_last_of(L'\\');
    if (pos != std::wstring::npos) MakeDirs(p.substr(0, pos));
    HANDLE h = CreateFileW(p.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD wr = 0; BOOL ok = WriteFile(h, data, (DWORD)n, &wr, nullptr);
    CloseHandle(h);
    return ok && wr == n;
}
static std::string ReadText(const std::wstring& p) { auto b = ReadAll(p); return std::string(b.begin(), b.end()); }

// ------------------------------------------------------------------------------------------------
// Embedded payload
// ------------------------------------------------------------------------------------------------
static bool GetPayload(int id, const void*& data, size_t& size)
{
    HRSRC r = FindResourceW(nullptr, MAKEINTRESOURCEW(id), (LPCWSTR)RT_RCDATA);
    if (!r) return false;
    HGLOBAL g = LoadResource(nullptr, r);
    if (!g) return false;
    data = LockResource(g); size = SizeofResource(nullptr, r);
    return data != nullptr;
}
static const PayloadFile* FindPayload(const wchar_t* rel)
{
    for (int i = 0; i < kPayloadCount; ++i) if (_wcsicmp(kPayload[i].relPath, rel) == 0) return &kPayload[i];
    return nullptr;
}
static bool PayloadMatchesFile(const wchar_t* rel, const std::wstring& path)
{
    const PayloadFile* pf = FindPayload(rel); if (!pf) return false;
    const void* d; size_t n; if (!GetPayload(pf->id, d, n)) return false;
    auto f = ReadAll(path);
    return f.size() == n && memcmp(f.data(), d, n) == 0;
}
static std::wstring ToWin(const wchar_t* rel) { std::wstring s = rel; for (auto& c : s) if (c == L'/') c = L'\\'; return s; }

// ------------------------------------------------------------------------------------------------
// Locating the game
// ------------------------------------------------------------------------------------------------
static const wchar_t* kExeRel = L"Brimstone\\Binaries\\Win64\\Brimstone-Win64-Shipping.exe";

static std::wstring RegString(HKEY root, const wchar_t* sub, const wchar_t* name)
{
    wchar_t buf[MAX_PATH * 2]; DWORD len = sizeof buf, type = 0;
    if (RegGetValueW(root, sub, name, RRF_RT_REG_SZ, &type, buf, &len) == ERROR_SUCCESS) return buf;
    return L"";
}
static std::wstring NormalizeSlashes(std::wstring s) { for (auto& c : s) if (c == L'/') c = L'\\'; return s; }

static std::wstring GameRootFrom(std::wstring dir)
{
    // accept the game root, Brimstone\, Binaries\Win64 or the exe itself
    dir = NormalizeSlashes(dir);
    while (!dir.empty() && dir.back() == L'\\') dir.pop_back();
    if (!IsDir(dir)) { size_t p = dir.find_last_of(L'\\'); if (p != std::wstring::npos) dir = dir.substr(0, p); }
    for (int up = 0; up < 4 && !dir.empty(); ++up) {
        if (Exists(Join(dir, kExeRel))) return dir;
        size_t p = dir.find_last_of(L'\\'); if (p == std::wstring::npos) break; dir = dir.substr(0, p);
    }
    return L"";
}

static std::wstring FindGameViaSteam()
{
    std::vector<std::wstring> steamDirs;
    for (auto s : { RegString(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath"),
                    RegString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WOW6432Node\\Valve\\Steam", L"InstallPath"),
                    RegString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Valve\\Steam", L"InstallPath") })
        if (!s.empty()) steamDirs.push_back(NormalizeSlashes(s));
    for (auto& steam : steamDirs) {
        std::wstring root = GameRootFrom(Join(steam, L"steamapps\\common\\Solasta 2"));
        if (!root.empty()) return root;
        std::string vdf = ReadText(Join(steam, L"steamapps\\libraryfolders.vdf"));
        size_t pos = 0;
        while ((pos = vdf.find("\"path\"", pos)) != std::string::npos) {
            size_t q1 = vdf.find('"', pos + 6); size_t q2 = q1 == std::string::npos ? q1 : vdf.find('"', q1 + 1);
            if (q1 == std::string::npos || q2 == std::string::npos) break;
            std::string lib = vdf.substr(q1 + 1, q2 - q1 - 1);
            std::string clean; for (size_t i = 0; i < lib.size(); ++i) { if (lib[i] == '\\' && i + 1 < lib.size() && lib[i + 1] == '\\') ++i; clean += lib[i]; }
            std::wstring wlib(clean.begin(), clean.end());
            root = GameRootFrom(Join(wlib, L"steamapps\\common\\Solasta 2"));
            if (!root.empty()) return root;
            pos = q2;
        }
    }
    return L"";
}

static std::wstring BrowseForGame()
{
    std::wstring result;
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return result;
    IFileOpenDialog* dlg = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)))) {
        DWORD opts = 0; dlg->GetOptions(&opts); dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
        dlg->SetTitle(L"Select your 'Solasta 2' game folder (Steam\\steamapps\\common\\Solasta 2)");
        if (SUCCEEDED(dlg->Show(nullptr))) {
            IShellItem* item = nullptr;
            if (SUCCEEDED(dlg->GetResult(&item))) {
                PWSTR path = nullptr;
                if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) { result = path; CoTaskMemFree(path); }
                item->Release();
            }
        }
        dlg->Release();
    }
    CoUninitialize();
    return result;
}

// ------------------------------------------------------------------------------------------------
// Game build check: the four byte signatures version.dll patches (see version_proxy.cpp)
// ------------------------------------------------------------------------------------------------
static int CheckPatchSites(const std::wstring& exe)
{
    static const std::vector<std::vector<uint8_t>> sigs = {
        { 0x41, 0xBD, 0x04, 0x00, 0x00, 0x00, 0x89, 0x44, 0x24, 0x5C, 0x48, 0x8D, 0x05 },
        { 0xC7, 0x80, 0xA0, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xC6, 0x40, 0x2A, 0x01 },
        { 0x44, 0x8D, 0x63, 0x04, 0x39, 0x9F, 0xC0, 0x00, 0x00, 0x00, 0x0F, 0x85 },
        { 0x83, 0xFB, 0x04, 0x48, 0x8B, 0xCF, 0x44, 0x0F, 0x4C, 0xE3 },
    };
    HANDLE h = CreateFileW(exe.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return -1;
    LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
    HANDLE m = CreateFileMappingW(h, nullptr, PAGE_READONLY, 0, 0, nullptr);
    const uint8_t* base = m ? (const uint8_t*)MapViewOfFile(m, FILE_MAP_READ, 0, 0, 0) : nullptr;
    int found = 0;
    if (base) {
        for (auto& sig : sigs) {
            size_t hits = 0;
            const uint8_t* cur = base; const uint8_t* end = base + sz.QuadPart;
            while (cur + sig.size() <= end) {
                cur = (const uint8_t*)memchr(cur, sig[0], end - cur - sig.size() + 1);
                if (!cur) break;
                if (memcmp(cur, sig.data(), sig.size()) == 0) ++hits;
                ++cur;
            }
            if (hits == 1) ++found;
        }
        UnmapViewOfFile(base);
    }
    if (m) CloseHandle(m);
    CloseHandle(h);
    return found;
}

static bool GameRunning()
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe; pe.dwSize = sizeof pe; bool running = false;
    if (Process32FirstW(snap, &pe)) do {
        if (_wcsicmp(pe.szExeFile, L"Brimstone-Win64-Shipping.exe") == 0) { running = true; break; }
    } while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    return running;
}

// The Narrator companion keeps running for a few seconds after the game closes: stop our copy before
// replacing or deleting it. Matched by full path, never by name alone (Windows' screen reader is also
// called Narrator.exe).
static void StopNarrator(const std::wstring& win64)
{
    std::wstring ours = Join(win64, L"Narrator\\SolastaNarrator.exe");
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W pe; pe.dwSize = sizeof pe;
    if (Process32FirstW(snap, &pe)) do {
        if (_wcsicmp(pe.szExeFile, L"SolastaNarrator.exe") != 0) continue;
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pe.th32ProcessID);
        if (!h) continue;
        wchar_t path[MAX_PATH]; DWORD n = MAX_PATH;
        if (QueryFullProcessImageNameW(h, 0, path, &n) && _wcsicmp(path, ours.c_str()) == 0) {
            TerminateProcess(h, 0); WaitForSingleObject(h, 3000);
        }
        CloseHandle(h);
    } while (Process32NextW(snap, &pe));
    CloseHandle(snap);
}

// ------------------------------------------------------------------------------------------------
// UE4SS mod list (mods.txt + mods.json)
// ------------------------------------------------------------------------------------------------
struct ModEntry { std::string name; bool enabled; };

static std::vector<ModEntry> ReadModsTxt(const std::wstring& modsDir)
{
    std::vector<ModEntry> mods;
    std::istringstream in(ReadText(Join(modsDir, L"mods.txt")));
    std::string line;
    while (std::getline(in, line)) {
        size_t c = line.find(':'); if (c == std::string::npos || line.find(';') == 0) continue;
        std::string name = line.substr(0, c), val = line.substr(c + 1);
        auto trim = [](std::string& s) { while (!s.empty() && isspace((unsigned char)s.back())) s.pop_back(); while (!s.empty() && isspace((unsigned char)s.front())) s.erase(0, 1); };
        trim(name); trim(val);
        if (!name.empty()) mods.push_back({ name, val == "1" });
    }
    return mods;
}
static void SetMod(std::vector<ModEntry>& mods, const std::string& name, bool enabled, bool front)
{
    for (auto it = mods.begin(); it != mods.end(); ++it) if (it->name == name) { mods.erase(it); break; }
    if (front) mods.insert(mods.begin(), { name, enabled }); else mods.push_back({ name, enabled });
}
static void RemoveMod(std::vector<ModEntry>& mods, const std::string& name)
{
    for (auto it = mods.begin(); it != mods.end(); ++it) if (it->name == name) { mods.erase(it); break; }
}
static bool WriteMods(const std::wstring& modsDir, std::vector<ModEntry> mods)
{
    // UE4SS wants its built-in Keybinds mod last
    ModEntry keybinds{ "Keybinds", true }; bool had = false;
    for (auto it = mods.begin(); it != mods.end(); ++it) if (it->name == "Keybinds") { keybinds = *it; mods.erase(it); had = true; break; }
    std::string txt, json = "[\n";
    for (auto& m : mods) txt += m.name + " : " + (m.enabled ? "1" : "0") + "\n";
    txt += "\n\n; Built-in keybinds, do not move up!\nKeybinds : " + std::string(keybinds.enabled ? "1" : "0") + "\n";
    mods.push_back(keybinds);
    for (size_t i = 0; i < mods.size(); ++i)
        json += "    {\n        \"mod_name\": \"" + mods[i].name + "\",\n        \"mod_enabled\": " + (mods[i].enabled ? "true" : "false") + "\n    }" + (i + 1 < mods.size() ? ",\n" : "\n");
    json += "]\n";
    (void)had;
    return WriteFileBytes(Join(modsDir, L"mods.txt"), txt.data(), txt.size()) && WriteFileBytes(Join(modsDir, L"mods.json"), json.data(), json.size());
}

// ------------------------------------------------------------------------------------------------
static bool ExtractKind(const std::wstring& win64, int kind, bool skipExisting, int& written)
{
    for (int i = 0; i < kPayloadCount; ++i) {
        if (kPayload[i].kind != kind) continue;
        std::wstring dst = Join(win64, ToWin(kPayload[i].relPath));
        if (skipExisting && Exists(dst)) continue;
        if (_wcsicmp(kPayload[i].relPath, L"BiggerParty.ini") == 0 && Exists(dst)) continue;   // keep the user's settings
        const void* d; size_t n;
        if (!GetPayload(kPayload[i].id, d, n)) { Say(L"  missing embedded file %s", kPayload[i].relPath); return false; }
        if (!WriteFileBytes(dst, d, n)) {
            DWORD e = GetLastError();
            Say(L"  FAILED to write %s (error %lu)", dst.c_str(), e);
            if (e == ERROR_ACCESS_DENIED) Say(L"  Access denied - right-click the installer and choose 'Run as administrator'.");
            if (e == ERROR_SHARING_VIOLATION) Say(L"  The file is in use - is the game still running?");
            return false;
        }
        ++written;
    }
    return true;
}

static bool DeleteTree(const std::wstring& dir)
{
    if (!IsDir(dir)) return true;
    std::wstring path = dir + L'\0'; path += L'\0';
    SHFILEOPSTRUCTW op = {}; op.wFunc = FO_DELETE; op.pFrom = path.c_str(); op.fFlags = FOF_NO_UI;
    return SHFileOperationW(&op) == 0;
}

static int Install(const std::wstring& root, bool spellbook, bool narrator)
{
    std::wstring win64 = Join(root, L"Brimstone\\Binaries\\Win64");
    std::wstring modsDir = Join(win64, L"ue4ss\\Mods");
    bool haveUE4SS = Exists(Join(win64, L"dwmapi.dll")) && Exists(Join(win64, L"ue4ss\\UE4SS.dll"));
    int written = 0;

    // version.dll slot
    std::wstring vdll = Join(win64, L"version.dll");
    if (Exists(vdll) && !PayloadMatchesFile(L"version.dll", vdll)) {
        Say(L"\nA different version.dll already exists in the game folder (another mod, e.g. Manual Dice Roll, uses the same slot).");
        if (!Ask(L"Replace it with BiggerParty's version.dll?", false)) { Say(L"Aborted."); return 2; }
    }

    if (!haveUE4SS) {
        Say(L"Installing UE4SS (script loader)...");
        if (!ExtractKind(win64, 0, false, written)) return 3;
        { std::string marker = "UE4SS was installed by the BiggerParty installer; its uninstaller may remove it.\n";
          WriteFileBytes(Join(win64, L"ue4ss\\installed-by-biggerparty.txt"), marker.data(), marker.size()); }
        auto mods = ReadModsTxt(modsDir);
        for (auto n : { "CheatManagerEnablerMod", "ConsoleEnablerMod", "ConsoleCommandsMod" }) SetMod(mods, n, false, false);
        WriteMods(modsDir, mods);
    } else {
        Say(L"UE4SS already present - leaving it as it is.");
    }

    Say(L"Installing BiggerParty...");
    if (!ExtractKind(win64, 1, false, written)) return 3;
    if (!ExtractKind(win64, 3, false, written)) return 3;      // README

    if (spellbook) {
        Say(L"Installing GiveSpellbook...");
        if (!ExtractKind(win64, 2, false, written)) return 3;
    }
    if (narrator) {
        Say(L"Installing Narrator...");
        StopNarrator(win64);
        if (!ExtractKind(win64, 4, false, written)) return 3;
    }

    auto mods = ReadModsTxt(modsDir);
    SetMod(mods, "BiggerParty", true, true);
    if (spellbook) SetMod(mods, "GiveSpellbook", true, true);
    if (narrator) SetMod(mods, "Narrator", true, true);
    if (IsDir(Join(modsDir, L"PartyProbe"))) SetMod(mods, "PartyProbe", false, false);   // research version; never both
    if (!WriteMods(modsDir, mods)) { Say(L"FAILED to update ue4ss\\Mods\\mods.txt"); return 3; }

    Say(L"\nDone - %d file(s) written to\n  %s", written, win64.c_str());
    Say(L"Config: %s (Enabled=1, PartySize=6). In game: Ctrl+Shift+Tab toggles the mod.", Join(win64, L"BiggerParty.ini").c_str());
    if (narrator) Say(L"Narrator: world events are read aloud (needs internet). Ctrl+Shift+N changes the voice, Ctrl+Shift+M mutes.");
    return 0;
}

static int Uninstall(const std::wstring& root)
{
    std::wstring win64 = Join(root, L"Brimstone\\Binaries\\Win64");
    std::wstring modsDir = Join(win64, L"ue4ss\\Mods");
    std::wstring vdll = Join(win64, L"version.dll");
    if (Exists(vdll)) {
        if (PayloadMatchesFile(L"version.dll", vdll) || Ask(L"version.dll differs from this installer's copy - delete it anyway?", false))
            DeleteFileW(vdll.c_str());
    }
    DeleteFileW(Join(win64, L"BiggerParty.ini").c_str());
    DeleteFileW(Join(win64, L"BiggerParty.log").c_str());
    DeleteFileW(Join(win64, L"BiggerParty-README.txt").c_str());
    DeleteTree(Join(modsDir, L"BiggerParty"));
    DeleteTree(Join(modsDir, L"PartyProbe"));
    bool removeSpellbook = IsDir(Join(modsDir, L"GiveSpellbook")) && Ask(L"Also remove the GiveSpellbook mod?", true);
    if (removeSpellbook) DeleteTree(Join(modsDir, L"GiveSpellbook"));
    bool removeNarrator = (IsDir(Join(modsDir, L"Narrator")) || IsDir(Join(win64, L"Narrator"))) && Ask(L"Also remove the Narrator mod (world-event voice, with its cached audio)?", true);
    if (removeNarrator) { StopNarrator(win64); DeleteTree(Join(modsDir, L"Narrator")); DeleteTree(Join(win64, L"Narrator")); }
    if (Exists(Join(modsDir, L"mods.txt"))) {
        auto mods = ReadModsTxt(modsDir);
        RemoveMod(mods, "BiggerParty"); RemoveMod(mods, "PartyProbe");
        if (removeSpellbook) RemoveMod(mods, "GiveSpellbook");
        if (removeNarrator) RemoveMod(mods, "Narrator");
        WriteMods(modsDir, mods);
    }
    bool ours = Exists(Join(win64, L"ue4ss\\installed-by-biggerparty.txt"));
    if (Exists(Join(win64, L"ue4ss\\UE4SS.dll")) && Ask(ours ? L"Also remove UE4SS (it was installed by this installer)?" : L"Also remove UE4SS (dwmapi.dll + ue4ss folder)? Other mods may depend on it.", ours)) {
        DeleteFileW(Join(win64, L"dwmapi.dll").c_str());
        DeleteTree(Join(win64, L"ue4ss"));
    }
    Say(L"\nBiggerParty removed from\n  %s", win64.c_str());
    return 0;
}

// ------------------------------------------------------------------------------------------------
int wmain(int argc, wchar_t** argv)
{
    if (_isatty(_fileno(stdout))) _setmode(_fileno(stdout), _O_U16TEXT); else { SetConsoleOutputCP(CP_UTF8); _setmode(_fileno(stdout), _O_U8TEXT); }
    bool doInstall = false, doUninstall = false, spellbook = false, narrator = false;
    std::wstring gameArg;
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (_wcsicmp(a.c_str(), L"/install") == 0) doInstall = true;
        else if (_wcsicmp(a.c_str(), L"/uninstall") == 0) doUninstall = true;
        else if (_wcsicmp(a.c_str(), L"/spellbook") == 0) spellbook = true;
        else if (_wcsicmp(a.c_str(), L"/narrator") == 0) narrator = true;
        else if (_wcsicmp(a.c_str(), L"/silent") == 0) g_silent = true;
        else if (_wcsicmp(a.c_str(), L"/game") == 0 && i + 1 < argc) gameArg = argv[++i];
    }

    Say(L"%s", kVersion);
    Say(L"=====================================================");

    // locate the game: /game argument, this exe's own folder, then Steam, then a folder picker
    std::wstring root;
    if (!gameArg.empty()) root = GameRootFrom(gameArg);
    if (root.empty()) { wchar_t self[MAX_PATH]; GetModuleFileNameW(nullptr, self, MAX_PATH); root = GameRootFrom(self); }
    if (root.empty()) root = FindGameViaSteam();
    if (root.empty() && !g_silent) {
        Say(L"Could not find Solasta II through Steam. Please pick the game folder in the dialog.");
        root = GameRootFrom(BrowseForGame());
    }
    if (root.empty()) { Say(L"Solasta II not found. Aborting."); Pause(); return 1; }
    Say(L"Game folder : %s", root.c_str());

    if (GameRunning()) { Say(L"\nSolasta II is running - close the game first, then run this again."); Pause(); return 1; }

    int sites = CheckPatchSites(Join(root, kExeRel));
    if (sites == 4) Say(L"Game build  : OK (all 4 patch sites found)");
    else Say(L"Game build  : WARNING - only %d of 4 patch sites found. The game was probably updated; the mod will install but stay inert until a matching version is released.", sites);

    std::wstring win64 = Join(root, L"Brimstone\\Binaries\\Win64");
    bool haveUE4SS = Exists(Join(win64, L"ue4ss\\UE4SS.dll"));
    bool haveMod = Exists(Join(win64, L"version.dll")) && IsDir(Join(win64, L"ue4ss\\Mods\\BiggerParty"));
    Say(L"UE4SS       : %s", haveUE4SS ? L"present" : L"will be installed");
    Say(L"BiggerParty : %s", haveMod ? L"installed (will be updated)" : L"not installed");
    bool haveNarrator = IsDir(Join(win64, L"ue4ss\\Mods\\Narrator"));
    if (haveNarrator) narrator = true;                            // an installed extra is kept up to date

    if (!doInstall && !doUninstall) {
        if (g_silent) doInstall = true;
        else {
            Say(L"\n  [Enter] Install / update BiggerParty%s", haveNarrator ? L" (+ Narrator, already installed)" : L"");
            Say(L"  [s]     ... + GiveSpellbook (multiclass-wizard spellbook fix)");
            Say(L"  [n]     ... + Narrator (reads world events aloud with an AI voice; needs internet)");
            Say(L"  [a]     ... + GiveSpellbook + Narrator");
            Say(L"  [u]     Uninstall");
            Say(L"  [q]     Quit");
            wprintf(L"> ");
            wchar_t buf[16] = {0}; fgetws(buf, 16, stdin);
            wchar_t c = (wchar_t)towlower(buf[0]);
            if (c == L'u') doUninstall = true;
            else if (c == L'q') return 0;
            else { doInstall = true; if (c == L's' || c == L'a') spellbook = true; if (c == L'n' || c == L'a') narrator = true; }
        }
    }

    int rc = doUninstall ? Uninstall(root) : Install(root, spellbook, narrator);
    if (rc == 0 && doInstall) Say(L"\nEveryone in a multiplayer session installs the same way. Start the game as usual - nothing else to launch.");
    Pause();
    return rc;
}
