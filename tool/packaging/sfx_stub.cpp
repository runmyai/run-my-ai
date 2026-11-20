// Self-extracting Windows launcher for Run My AI.
// Unpacks LZMS-compressed RCDATA resource 102 keyed by RCDATA 101 version tag
// into %LOCALAPPDATA%\RunMyAI\app\<tag> and launches runmyai.exe. Older
// versions' folders there are removed (a folder still in use stays until a
// later start).
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <compressapi.h>
#include <shellapi.h>
#include <shlobj.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "cabinet.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")

namespace {

static const wchar_t * kTitle = L"Run My AI";

static void fail_msg(const std::wstring & msg) {
    MessageBoxW(nullptr, msg.c_str(), kTitle, MB_OK | MB_ICONERROR);
}

static bool load_rcdata(int res_id, const uint8_t *& ptr, DWORD & size) {
    HRSRC hr = FindResourceW(nullptr, MAKEINTRESOURCEW(res_id), RT_RCDATA);
    if (!hr) return false;
    size = SizeofResource(nullptr, hr);
    HGLOBAL hg = LoadResource(nullptr, hr);
    if (!hg || size == 0) return false;
    ptr = static_cast<const uint8_t *>(LockResource(hg));
    return ptr != nullptr;
}

static std::wstring utf8_to_wide(const char * s, size_t len) {
    if (len == 0) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s, static_cast<int>(len), nullptr, 0);
    if (n <= 0) return L"";
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, static_cast<int>(len), out.data(), n);
    return out;
}

static bool create_dirs(const std::wstring & dir) {
    if (dir.empty()) return false;
    DWORD attr = GetFileAttributesW(dir.c_str());
    if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) return true;
    int rc = SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
    return rc == ERROR_SUCCESS || rc == ERROR_ALREADY_EXISTS || rc == ERROR_FILE_EXISTS;
}

static bool write_all(const std::wstring & path, const uint8_t * data, uint64_t size) {
    HANDLE hf = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hf == INVALID_HANDLE_VALUE) return false;
    uint64_t done = 0;
    bool ok = true;
    while (done < size) {
        DWORD chunk = static_cast<DWORD>((size - done) > 0x40000000ULL ? 0x40000000ULL : (size - done));
        DWORD written = 0;
        if (!WriteFile(hf, data + done, chunk, &written, nullptr) || written != chunk) {
            ok = false;
            break;
        }
        done += written;
    }
    CloseHandle(hf);
    return ok;
}

static bool unpack_bundle(const std::wstring & target_dir) {
    const uint8_t * comp = nullptr;
    DWORD comp_sz = 0;
    if (!load_rcdata(102, comp, comp_sz)) return false;

    DECOMPRESSOR_HANDLE dh = nullptr;
    if (!CreateDecompressor(COMPRESS_ALGORITHM_LZMS, nullptr, &dh)) return false;

    SIZE_T raw_sz = 0;
    if (!Decompress(dh, const_cast<uint8_t *>(comp), comp_sz, nullptr, 0, &raw_sz)) {
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || raw_sz == 0) {
            CloseDecompressor(dh);
            return false;
        }
    }

    std::vector<uint8_t> raw(raw_sz);
    SIZE_T actual_sz = 0;
    BOOL decomp_ok = Decompress(dh, const_cast<uint8_t *>(comp), comp_sz, raw.data(), raw_sz, &actual_sz);
    CloseDecompressor(dh);
    if (!decomp_ok || actual_sz < 8 || std::memcmp(raw.data(), "RMAI", 4) != 0) return false;

    size_t off = 4;
    uint32_t count = 0;
    std::memcpy(&count, raw.data() + off, 4);
    off += 4;

    std::wstring tmp_dir = target_dir + L".tmp." + std::to_wstring(GetCurrentProcessId());
    if (!create_dirs(tmp_dir)) return false;

    for (uint32_t i = 0; i < count; ++i) {
        if (off + 4 > actual_sz) return false;
        uint32_t path_len = 0;
        std::memcpy(&path_len, raw.data() + off, 4);
        off += 4;
        if (path_len == 0 || off + path_len + 8 > actual_sz) return false;
        std::wstring rel = utf8_to_wide(reinterpret_cast<const char *>(raw.data() + off), path_len);
        off += path_len;
        if (rel.empty() || rel.find(L"..") != std::wstring::npos || rel[0] == L'\\' || rel[0] == L'/') return false;
        for (wchar_t & ch : rel) {
            if (ch == L'/') ch = L'\\';
        }
        uint64_t fsz = 0;
        std::memcpy(&fsz, raw.data() + off, 8);
        off += 8;
        if (off + fsz > actual_sz) return false;

        std::wstring dst = tmp_dir + L"\\" + rel;
        size_t slash = dst.find_last_of(L'\\');
        if (slash != std::wstring::npos && !create_dirs(dst.substr(0, slash))) return false;
        if (!write_all(dst, raw.data() + off, fsz)) return false;
        off += static_cast<size_t>(fsz);
    }

    const uint8_t ok_byte = '1';
    if (!write_all(tmp_dir + L"\\.ready", &ok_byte, 1)) return false;

    DWORD attr = GetFileAttributesW(target_dir.c_str());
    if (attr != INVALID_FILE_ATTRIBUTES) {
        std::wstring stale = target_dir + L".old." + std::to_wstring(GetCurrentProcessId());
        MoveFileW(target_dir.c_str(), stale.c_str());
    }
    return MoveFileW(tmp_dir.c_str(), target_dir.c_str()) != 0;
}

static bool file_exists(const std::wstring & p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

// Removes every folder in base_dir except keep: older versions and leftovers
// of an interrupted unpack. A folder whose files are in use (an older app still
// closing) fails to delete and is tried again at the next start.
static void remove_old_versions(const std::wstring & base_dir, const std::wstring & keep) {
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((base_dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L".." || name == keep) continue;
        // a version still running holds its program open: leave that folder whole
        HANDLE exe = CreateFileW((base_dir + L"\\" + name + L"\\runmyai.exe").c_str(), GENERIC_READ, 0, nullptr,
                                 OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (exe == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION) continue;
        if (exe != INVALID_HANDLE_VALUE) CloseHandle(exe);
        // a double-null-terminated path, as SHFileOperation wants
        std::wstring from = base_dir + L"\\" + name;
        from.push_back(L'\0');
        SHFILEOPSTRUCTW op{};
        op.wFunc = FO_DELETE;
        op.pFrom = from.c_str();
        op.fFlags = FOF_NO_UI;
        SHFileOperationW(&op);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

static std::wstring args_after_exe(const wchar_t * cmd) {
    if (!cmd) return L"";
    const wchar_t * p = cmd;
    while (*p == L' ' || *p == L'\t') ++p;
    if (*p == L'"') {
        ++p;
        while (*p && *p != L'"') ++p;
        if (*p == L'"') ++p;
    } else {
        while (*p && *p != L' ' && *p != L'\t') ++p;
    }
    while (*p == L' ' || *p == L'\t') ++p;
    return std::wstring(p);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int show_cmd) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    const uint8_t * ver_ptr = nullptr;
    DWORD ver_sz = 0;
    if (!load_rcdata(101, ver_ptr, ver_sz)) {
        fail_msg(L"Launcher resource metadata is missing.");
        return 1;
    }
    std::wstring ver_tag = utf8_to_wide(reinterpret_cast<const char *>(ver_ptr), ver_sz);

    PWSTR local_app = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local_app)) || !local_app) {
        fail_msg(L"Could not locate LocalAppData.");
        return 1;
    }
    std::wstring base_dir = std::wstring(local_app) + L"\\RunMyAI\\app";
    CoTaskMemFree(local_app);
    create_dirs(base_dir);

    std::wstring target_dir = base_dir + L"\\" + ver_tag;
    std::wstring exe_path = target_dir + L"\\runmyai.exe";
    std::wstring ready_path = target_dir + L"\\.ready";

    if (!file_exists(ready_path) || !file_exists(exe_path)) {
        std::wstring mtx_name = L"Local\\RunMyAI_Unpack_" + ver_tag;
        HANDLE hm = CreateMutexW(nullptr, FALSE, mtx_name.c_str());
        if (hm) WaitForSingleObject(hm, INFINITE);
        if (!file_exists(ready_path) || !file_exists(exe_path)) {
            if (!unpack_bundle(target_dir)) {
                if (hm) {
                    ReleaseMutex(hm);
                    CloseHandle(hm);
                }
                fail_msg(L"Failed to unpack Run My AI into:\n" + target_dir);
                return 1;
            }
        }
        if (hm) {
            ReleaseMutex(hm);
            CloseHandle(hm);
        }
    }

    std::wstring extra = args_after_exe(GetCommandLineW());
    std::wstring full_cmd = L"\"" + exe_path + L"\"" + (extra.empty() ? L"" : L" " + extra);
    std::vector<wchar_t> cmd_buf(full_cmd.begin(), full_cmd.end());
    cmd_buf.push_back(L'\0');

    // the app replaces this launcher with a new version and starts it again (lib/system/relaunch.dart)
    std::vector<wchar_t> self(32768);
    DWORD self_len = GetModuleFileNameW(nullptr, self.data(), static_cast<DWORD>(self.size()));
    if (self_len > 0 && self_len < self.size()) SetEnvironmentVariableW(L"RUNMYAI_LAUNCHER", self.data());

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = static_cast<WORD>(show_cmd);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(exe_path.c_str(), cmd_buf.data(), nullptr, nullptr, FALSE, 0, nullptr, target_dir.c_str(), &si, &pi)) {
        fail_msg(L"Failed to launch Run My AI (error " + std::to_wstring(GetLastError()) + L").");
        return 1;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    remove_old_versions(base_dir, ver_tag);
    return 0;
}
