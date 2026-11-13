// The single-file Glaze setup: this executable with the setup window and the
// Glaze build appended to it.
//
//   [launcher] [setup window, packed] [Glaze build, zip] [footer]
//
// Run as GlazeSetup.exe, it unpacks the setup window (a small Flutter app,
// windows/installer/app) into a folder of its own under %TEMP%, copies the
// Glaze zip next to it, runs the window with its own arguments passed on and
// waits for it, then deletes the folder. Everything the user sees is drawn by
// that window; this part has no UI beyond an error box.
//
// Built with -DGLAZE_PACKER it is the console tool CI uses to make the file:
//
//   setup_pack.exe <launcher.exe> <setup window dir> <glaze.zip|-> <out.exe>
//       [--store]
//
// The window's files are compressed with the Windows Compression API (LZMS,
// Windows 8 and later), so neither side needs a library. --store keeps them as
// they are; Wine has no Compression API, so local tests use it.
//
// `--selftest <dir>` on the packed file unpacks the setup window into <dir>
// and exits, for CI to check a fresh build without opening a window.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <compressapi.h>
#include <shellapi.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

// One source builds both executables; [[maybe_unused]] marks what only the
// launcher calls.

constexpr char kMagic[8] = {'G', 'L', 'Z', 'S', 'E', 'T', 'U', 'P'};
constexpr uint32_t kVersion = 1;
constexpr uint32_t kMethodStore = 0;
constexpr uint32_t kMethodLzms = 1;

// Last 64 bytes of a packed file. Offsets are from the start of the file.
// Read by the setup window too (lib/src/package.dart): keep the two in step.
#pragma pack(push, 1)
struct Footer {
  char magic[8];
  uint32_t version;
  uint32_t method;
  uint64_t ui_offset;
  uint64_t ui_size;      // as stored
  uint64_t ui_raw_size;  // unpacked
  uint64_t payload_offset;
  uint64_t payload_size;  // 0 for the uninstaller copy, which carries none
  uint8_t reserved[8];
};
#pragma pack(pop)
static_assert(sizeof(Footer) == 64, "footer is 64 bytes");

bool ReadFileRange(const fs::path& path, uint64_t offset, uint64_t size,
                   std::vector<char>& out) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  in.seekg(static_cast<std::streamoff>(offset));
  out.resize(static_cast<size_t>(size));
  in.read(out.data(), static_cast<std::streamsize>(size));
  return static_cast<uint64_t>(in.gcount()) == size;
}

[[maybe_unused]] bool ReadFooter(const fs::path& path, Footer& footer) {
  std::error_code ec;
  const auto length = fs::file_size(path, ec);
  if (ec || length < sizeof(Footer)) return false;
  std::vector<char> bytes;
  if (!ReadFileRange(path, length - sizeof(Footer), sizeof(Footer), bytes)) {
    return false;
  }
  std::memcpy(&footer, bytes.data(), sizeof(Footer));
  return std::memcmp(footer.magic, kMagic, sizeof(kMagic)) == 0 &&
         footer.version == kVersion;
}

// The window's files, one after another: u32 path length, the path (UTF-8,
// forward slashes, relative), u64 size, the bytes.
[[maybe_unused]] bool Unpack(const std::vector<char>& raw, const fs::path& dir) {
  size_t at = 0;
  while (at < raw.size()) {
    uint32_t name_length = 0;
    uint64_t size = 0;
    if (raw.size() - at < sizeof(name_length)) return false;
    std::memcpy(&name_length, raw.data() + at, sizeof(name_length));
    at += sizeof(name_length);
    if (raw.size() - at < name_length + sizeof(size)) return false;
    const std::string name(raw.data() + at, name_length);
    at += name_length;
    std::memcpy(&size, raw.data() + at, sizeof(size));
    at += sizeof(size);
    if (raw.size() - at < size) return false;

    const fs::path relative = fs::u8path(name).lexically_normal();
    // A packed path never leaves the folder it is unpacked into.
    if (relative.is_absolute() || relative.empty() ||
        *relative.begin() == fs::path("..")) {
      return false;
    }
    const fs::path target = dir / relative;
    std::error_code ec;
    fs::create_directories(target.parent_path(), ec);
    std::ofstream out(target, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out.write(raw.data() + at, static_cast<std::streamsize>(size));
    if (!out) return false;
    at += static_cast<size_t>(size);
  }
  return true;
}

[[maybe_unused]] bool Decompress(const Footer& footer, const std::vector<char>& stored,
                std::vector<char>& raw) {
  if (footer.method == kMethodStore) {
    raw = stored;
    return raw.size() == footer.ui_raw_size;
  }
  if (footer.method != kMethodLzms) return false;
  DECOMPRESSOR_HANDLE handle = nullptr;
  if (!CreateDecompressor(COMPRESS_ALGORITHM_LZMS, nullptr, &handle)) {
    return false;
  }
  raw.resize(static_cast<size_t>(footer.ui_raw_size));
  SIZE_T written = 0;
  // Non-const in MinGW's header, const in the SDK's.
  const BOOL ok = ::Decompress(handle, const_cast<char*>(stored.data()),
                               stored.size(), raw.data(), raw.size(), &written);
  CloseDecompressor(handle);
  return ok && written == raw.size();
}

// Unpacks the setup window of [package] into [dir].
[[maybe_unused]] bool ExtractWindow(const fs::path& package, const Footer& footer,
                   const fs::path& dir) {
  std::vector<char> stored;
  std::vector<char> raw;
  return ReadFileRange(package, footer.ui_offset, footer.ui_size, stored) &&
         Decompress(footer, stored, raw) && Unpack(raw, dir);
}

[[maybe_unused]] bool CopyRange(const fs::path& from, uint64_t offset, uint64_t size,
               const fs::path& to) {
  std::ifstream in(from, std::ios::binary);
  std::ofstream out(to, std::ios::binary | std::ios::trunc);
  if (!in || !out) return false;
  in.seekg(static_cast<std::streamoff>(offset));
  std::vector<char> buffer(1 << 20);
  while (size > 0) {
    const auto chunk = static_cast<std::streamsize>(
        size < buffer.size() ? size : buffer.size());
    in.read(buffer.data(), chunk);
    if (in.gcount() != chunk) return false;
    out.write(buffer.data(), chunk);
    size -= static_cast<uint64_t>(chunk);
  }
  return static_cast<bool>(out);
}

[[maybe_unused]] fs::path SelfPath() {
  std::wstring buffer(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length =
        GetModuleFileNameW(nullptr, buffer.data(),
                           static_cast<DWORD>(buffer.size()));
    if (length < buffer.size()) {
      buffer.resize(length);
      return fs::path(buffer);
    }
    buffer.resize(buffer.size() * 2);
  }
}

// One argument as CommandLineToArgvW will read it back.
[[maybe_unused]] std::wstring Quote(const std::wstring& arg) {
  if (!arg.empty() && arg.find_first_of(L" \t\"") == std::wstring::npos) {
    return arg;
  }
  std::wstring out = L"\"";
  size_t backslashes = 0;
  for (const wchar_t c : arg) {
    if (c == L'\\') {
      ++backslashes;
      continue;
    }
    if (c == L'"') {
      out.append(backslashes * 2 + 1, L'\\');
    } else {
      out.append(backslashes, L'\\');
    }
    backslashes = 0;
    out += c;
  }
  out.append(backslashes * 2, L'\\');
  out += L'"';
  return out;
}

#ifdef GLAZE_PACKER

bool ReadAll(const fs::path& path, std::vector<char>& out) {
  std::error_code ec;
  const auto size = fs::file_size(path, ec);
  return !ec && ReadFileRange(path, 0, size, out);
}

bool PackDirectory(const fs::path& dir, std::vector<char>& raw) {
  std::error_code ec;
  for (fs::recursive_directory_iterator it(dir, ec), end; it != end;
       it.increment(ec)) {
    if (ec) return false;
    if (!it->is_regular_file()) continue;
    std::vector<char> bytes;
    if (!ReadAll(it->path(), bytes)) return false;
    const std::string name =
        fs::relative(it->path(), dir).generic_u8string();
    const auto name_length = static_cast<uint32_t>(name.size());
    const auto size = static_cast<uint64_t>(bytes.size());
    raw.insert(raw.end(), reinterpret_cast<const char*>(&name_length),
               reinterpret_cast<const char*>(&name_length) + 4);
    raw.insert(raw.end(), name.begin(), name.end());
    raw.insert(raw.end(), reinterpret_cast<const char*>(&size),
               reinterpret_cast<const char*>(&size) + 8);
    raw.insert(raw.end(), bytes.begin(), bytes.end());
  }
  return true;
}

bool Compress(const std::vector<char>& raw, std::vector<char>& out) {
  COMPRESSOR_HANDLE handle = nullptr;
  if (!CreateCompressor(COMPRESS_ALGORITHM_LZMS, nullptr, &handle)) {
    return false;
  }
  SIZE_T needed = 0;
  ::Compress(handle, const_cast<char*>(raw.data()), raw.size(), nullptr, 0,
             &needed);
  out.resize(needed);
  SIZE_T written = 0;
  const BOOL ok = ::Compress(handle, const_cast<char*>(raw.data()), raw.size(),
                             out.data(), out.size(), &written);
  CloseCompressor(handle);
  out.resize(written);
  return ok;
}

int Pack(int argc, wchar_t** argv) {
  if (argc < 5) {
    std::fwprintf(stderr,
                  L"usage: setup_pack <launcher.exe> <window dir> "
                  L"<glaze.zip|-> <out.exe> [--store]\n");
    return 2;
  }
  const fs::path launcher = argv[1];
  const fs::path window_dir = argv[2];
  const std::wstring payload = argv[3];
  const fs::path out_path = argv[4];
  const bool store = argc > 5 && std::wstring(argv[5]) == L"--store";

  std::vector<char> head;
  std::vector<char> raw;
  std::vector<char> ui;
  std::vector<char> zip;
  if (!ReadAll(launcher, head)) {
    std::fwprintf(stderr, L"cannot read %ls\n", launcher.c_str());
    return 1;
  }
  if (!PackDirectory(window_dir, raw) || raw.empty()) {
    std::fwprintf(stderr, L"cannot pack %ls\n", window_dir.c_str());
    return 1;
  }
  if (store) {
    ui = raw;
  } else if (!Compress(raw, ui)) {
    std::fwprintf(stderr, L"compression failed (%lu)\n", GetLastError());
    return 1;
  }
  if (payload != L"-" && !ReadAll(payload, zip)) {
    std::fwprintf(stderr, L"cannot read %ls\n", payload.c_str());
    return 1;
  }

  Footer footer{};
  std::memcpy(footer.magic, kMagic, sizeof(kMagic));
  footer.version = kVersion;
  footer.method = store ? kMethodStore : kMethodLzms;
  footer.ui_offset = head.size();
  footer.ui_size = ui.size();
  footer.ui_raw_size = raw.size();
  footer.payload_offset = footer.ui_offset + footer.ui_size;
  footer.payload_size = zip.size();

  std::ofstream out(out_path, std::ios::binary | std::ios::trunc);
  out.write(head.data(), static_cast<std::streamsize>(head.size()));
  out.write(ui.data(), static_cast<std::streamsize>(ui.size()));
  out.write(zip.data(), static_cast<std::streamsize>(zip.size()));
  out.write(reinterpret_cast<const char*>(&footer), sizeof(footer));
  if (!out) {
    std::fwprintf(stderr, L"cannot write %ls\n", out_path.c_str());
    return 1;
  }
  std::fwprintf(stdout, L"window %llu -> %llu bytes, glaze %llu bytes\n",
                static_cast<unsigned long long>(raw.size()),
                static_cast<unsigned long long>(ui.size()),
                static_cast<unsigned long long>(zip.size()));
  return 0;
}

#else  // GLAZE_PACKER

void Fail(const wchar_t* what) {
  MessageBoxW(nullptr, what, L"Glaze Setup", MB_ICONERROR | MB_OK);
}

int Run(int argc, wchar_t** argv) {
  const fs::path self = SelfPath();
  Footer footer{};
  if (!ReadFooter(self, footer)) {
    Fail(L"This setup file is damaged. Download it again.");
    return 1;
  }

  if (argc >= 3 && std::wstring(argv[1]) == L"--selftest") {
    return ExtractWindow(self, footer, argv[2]) ? 0 : 1;
  }

  wchar_t temp[MAX_PATH + 1];
  GetTempPathW(MAX_PATH + 1, temp);
  const fs::path dir = fs::path(temp) / (L"GlazeSetup-" +
                                         std::to_wstring(GetCurrentProcessId()) +
                                         L"-" + std::to_wstring(GetTickCount()));
  std::error_code ec;
  fs::create_directories(dir, ec);

  const fs::path window_dir = dir / L"window";
  const fs::path zip = dir / L"glaze.zip";
  int code = 1;
  if (!ExtractWindow(self, footer, window_dir) ||
      (footer.payload_size > 0 &&
       !CopyRange(self, footer.payload_offset, footer.payload_size, zip))) {
    Fail(L"Glaze Setup could not unpack itself. Check that there is free "
         L"space on the system drive and try again.");
  } else {
    std::wstring command = Quote((window_dir / L"GlazeSetup.exe").wstring());
    for (int i = 1; i < argc; ++i) command += L" " + Quote(argv[i]);
    command += L" --package " + Quote(self.wstring());
    if (footer.payload_size > 0) command += L" --payload " + Quote(zip.wstring());

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                       nullptr, window_dir.c_str(), &startup, &process)) {
      WaitForSingleObject(process.hProcess, INFINITE);
      DWORD exit_code = 1;
      GetExitCodeProcess(process.hProcess, &exit_code);
      code = static_cast<int>(exit_code);
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
    } else {
      Fail(L"Glaze Setup could not start.");
    }
  }

  // The window has exited, so nothing holds its files any more; a few tries
  // cover an antivirus still scanning them.
  for (int attempt = 0; attempt < 10; ++attempt) {
    fs::remove_all(dir, ec);
    if (!fs::exists(dir)) break;
    Sleep(300);
  }
  return code;
}

#endif  // GLAZE_PACKER

}  // namespace

#ifdef GLAZE_PACKER
int wmain(int argc, wchar_t** argv) { return Pack(argc, argv); }
#else
int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  const int code = Run(argc, argv);
  LocalFree(argv);
  return code;
}
#endif
