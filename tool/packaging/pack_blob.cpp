// Packs a Flutter Windows Release directory tree into an LZMS-compressed
// payload for embedding inside the Run My AI self-extracting launcher.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <compressapi.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#pragma comment(lib, "cabinet.lib")

namespace fs = std::filesystem;

static void append_u32(std::vector<uint8_t> & buf, uint32_t v) {
    uint8_t b[4];
    std::memcpy(b, &v, 4);
    buf.insert(buf.end(), b, b + 4);
}

static void append_u64(std::vector<uint8_t> & buf, uint64_t v) {
    uint8_t b[8];
    std::memcpy(b, &v, 8);
    buf.insert(buf.end(), b, b + 8);
}

int wmain(int argc, wchar_t ** argv) {
    if (argc != 3) {
        std::fwprintf(stderr, L"usage: pack_blob <input_dir> <output_lzms>\n");
        return 2;
    }
    fs::path root = fs::path(argv[1]);
    std::vector<fs::path> files;
    for (auto const & entry : fs::recursive_directory_iterator(root)) {
        if (entry.is_regular_file()) {
            files.push_back(entry.path());
        }
    }
    std::sort(files.begin(), files.end());

    std::vector<uint8_t> raw = {'R', 'M', 'A', 'I'};
    append_u32(raw, static_cast<uint32_t>(files.size()));

    for (auto const & p : files) {
        std::string rel = fs::relative(p, root).generic_u8string();
        std::ifstream in(p, std::ios::binary | std::ios::ate);
        if (!in) return 3;
        uint64_t fsz = static_cast<uint64_t>(in.tellg());
        in.seekg(0, std::ios::beg);
        append_u32(raw, static_cast<uint32_t>(rel.size()));
        raw.insert(raw.end(), rel.begin(), rel.end());
        append_u64(raw, fsz);
        size_t old_sz = raw.size();
        raw.resize(old_sz + static_cast<size_t>(fsz));
        if (fsz > 0 && !in.read(reinterpret_cast<char *>(raw.data() + old_sz), static_cast<std::streamsize>(fsz))) {
            return 4;
        }
    }

    COMPRESSOR_HANDLE ch = nullptr;
    if (!CreateCompressor(COMPRESS_ALGORITHM_LZMS, nullptr, &ch)) return 5;
    SIZE_T comp_sz = 0;
    if (!Compress(ch, raw.data(), raw.size(), nullptr, 0, &comp_sz)) {
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
            CloseCompressor(ch);
            return 6;
        }
    }
    std::vector<uint8_t> comp(comp_sz);
    SIZE_T actual_sz = 0;
    BOOL ok = Compress(ch, raw.data(), raw.size(), comp.data(), comp_sz, &actual_sz);
    CloseCompressor(ch);
    if (!ok) return 7;

    std::ofstream out(fs::path(argv[2]), std::ios::binary);
    if (!out) return 8;
    out.write(reinterpret_cast<const char *>(comp.data()), static_cast<std::streamsize>(actual_sz));
    std::wprintf(L"Packed %zu files (%zu -> %zu bytes LZMS)\n", files.size(), raw.size(), static_cast<size_t>(actual_sz));
    return out ? 0 : 9;
}
