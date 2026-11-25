#include "runtime_check.h"

#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

namespace {

// Visual Studio 2022 17.10 (MSVC 14.40) changed std::mutex; code built with it
// crashes against an older msvcp140.dll. See docs/BUILD_NOTES.md.
constexpr WORD kMinMajor = 14;
constexpr WORD kMinMinor = 40;

constexpr wchar_t kDownloadUrl[] =
    L"https://aka.ms/vs/17/release/vc_redist.x64.exe";

struct RuntimeInfo {
  WORD major = 0;
  WORD minor = 0;
  std::wstring path;
};

// The msvcp140.dll this process runs on: the one already loaded by Glaze.exe's
// plugins, or the one Windows would pick now.
bool LoadedRuntime(RuntimeInfo* out) {
  HMODULE module = ::GetModuleHandleW(L"msvcp140.dll");
  if (module == nullptr) {
    module = ::LoadLibraryExW(L"msvcp140.dll", nullptr,
                              LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  }
  if (module == nullptr) return false;

  std::vector<wchar_t> path(MAX_PATH);
  DWORD length = 0;
  for (;;) {
    length = ::GetModuleFileNameW(module, path.data(),
                                  static_cast<DWORD>(path.size()));
    if (length == 0) return false;
    if (length < path.size()) break;
    path.resize(path.size() * 2);
  }

  DWORD ignored = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(path.data(), &ignored);
  if (size == 0) return false;
  std::vector<BYTE> data(size);
  if (!::GetFileVersionInfoW(path.data(), 0, size, data.data())) return false;

  VS_FIXEDFILEINFO* info = nullptr;
  UINT info_size = 0;
  if (!::VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&info),
                        &info_size) ||
      info == nullptr || info_size < sizeof(VS_FIXEDFILEINFO)) {
    return false;
  }
  out->major = HIWORD(info->dwFileVersionMS);
  out->minor = LOWORD(info->dwFileVersionMS);
  out->path.assign(path.data(), length);
  return true;
}

bool ReaderUsesRussian() {
  switch (PRIMARYLANGID(::GetUserDefaultUILanguage())) {
    case LANG_RUSSIAN:
    case LANG_UKRAINIAN:
    case LANG_BELARUSIAN:
      return true;
    default:
      return false;
  }
}

std::wstring Message(const RuntimeInfo& runtime) {
  const std::wstring version =
      std::to_wstring(runtime.major) + L"." + std::to_wstring(runtime.minor);
  if (ReaderUsesRussian()) {
    return L"Библиотека Microsoft Visual C++ на этом компьютере слишком "
           L"старая (версия " +
           version +
           L"), и Glaze вылетит при открытии чата.\n\n"
           L"Установите свежий Microsoft Visual C++ Redistributable (x64) — "
           L"бесплатный компонент Windows от Microsoft. Если Glaze скачан "
           L"архивом, можно также скачать его заново целиком: нужные файлы "
           L"лежат рядом с Glaze.exe.\n\n"
           L"Файл: " +
           runtime.path +
           L"\n\n"
           L"Да — открыть страницу загрузки и закрыть Glaze.\n"
           L"Нет — всё равно запустить.";
  }
  return L"The Microsoft Visual C++ runtime on this computer is too old "
         L"(version " +
         version +
         L"), and Glaze will crash when a chat opens.\n\n"
         L"Install the latest Microsoft Visual C++ Redistributable (x64), a "
         L"free Windows component from Microsoft. If you unpacked Glaze from "
         L"a zip, downloading it again in full also works: the files it needs "
         L"sit next to Glaze.exe.\n\n"
         L"File: " +
         runtime.path +
         L"\n\n"
         L"Yes: open the download page and close Glaze.\n"
         L"No: start anyway.";
}

}  // namespace

bool CheckVisualCppRuntime() {
  RuntimeInfo runtime;
  if (!LoadedRuntime(&runtime)) return true;
  if (runtime.major > kMinMajor ||
      (runtime.major == kMinMajor && runtime.minor >= kMinMinor)) {
    return true;
  }
  const std::wstring text = Message(runtime);
  const int answer =
      ::MessageBoxW(nullptr, text.c_str(), L"Glaze",
                    MB_YESNO | MB_ICONWARNING | MB_SETFOREGROUND);
  if (answer != IDYES) return true;
  ::ShellExecuteW(nullptr, L"open", kDownloadUrl, nullptr, nullptr,
                  SW_SHOWNORMAL);
  return false;
}
