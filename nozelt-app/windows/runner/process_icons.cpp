#include "process_icons.h"

#include <shellapi.h>
#include <tlhelp32.h>
#include <objidl.h>
#include <gdiplus.h>
#include <algorithm>
#include <utility>

namespace {
std::wstring ImagePath(const std::wstring& name) {
  // Names come from live core snapshots, not PATH lookup or remote files.
  if (name.empty() || name.find_first_of(L"\\/:") != std::wstring::npos)
    return {};
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return {};
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  std::wstring path;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (_wcsicmp(name.c_str(), entry.szExeFile) != 0) continue;
      HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                   entry.th32ProcessID);
      if (!process) continue;
      wchar_t buffer[32768];
      DWORD size = ARRAYSIZE(buffer);
      if (QueryFullProcessImageNameW(process, 0, buffer, &size))
        path.assign(buffer, size);
      CloseHandle(process);
      if (!path.empty()) break;
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  // Never resolve resources over a network share while the UI is waiting.
  if (path.size() < 3 || path[1] != L':' ||
      GetDriveTypeW(path.substr(0, 3).c_str()) == DRIVE_REMOTE) return {};
  return path;
}

std::vector<uint8_t> DrawIconPixels(HICON icon, uint8_t background) {
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = 32;
  info.bmiHeader.biHeight = -32;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HDC dc = CreateCompatibleDC(nullptr);
  if (!dc) return {};
  HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!bitmap) { DeleteDC(dc); return {}; }
  HGDIOBJ previous = SelectObject(dc, bitmap);
  memset(pixels, background, 32 * 32 * 4);
  const BOOL drawn = DrawIconEx(dc, 0, 0, icon, 32, 32, 0, nullptr, DI_NORMAL);
  GdiFlush();
  std::vector<uint8_t> bytes;
  if (drawn) {
    const auto* start = static_cast<uint8_t*>(pixels);
    bytes.assign(start, start + 32 * 32 * 4);
  }
  SelectObject(dc, previous);
  DeleteObject(bitmap);
  DeleteDC(dc);
  return bytes;
}
}  // namespace

ProcessIcons::Bytes ProcessIcons::Read(const std::wstring& process) {
  const auto path = ImagePath(process);
  if (path.empty()) return {};
  HICON icon = nullptr;
  const UINT count = ExtractIconExW(path.c_str(), 0, &icon, nullptr, 1);
  if (count == 0 || count == UINT_MAX || !icon) return {};
  auto black = DrawIconPixels(icon, 0);
  auto white = DrawIconPixels(icon, 255);
  DestroyIcon(icon);
  if (black.empty() || white.empty()) return {};
  // Recover alpha from black/white composites. Works for both modern alpha
  // resources and legacy monochrome transparency masks without black halos.
  for (size_t i = 0; i < black.size(); i += 4) {
    int difference = 0;
    for (size_t channel = 0; channel < 3; ++channel)
      difference = (std::max)(difference,
          static_cast<int>(white[i + channel]) - black[i + channel]);
    black[i + 3] = static_cast<uint8_t>(255 - difference);
  }
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  if (Gdiplus::GdiplusStartup(&token, &input, nullptr) != Gdiplus::Ok) return {};
  Bytes result;
  {
    Gdiplus::Bitmap bitmap(32, 32, 128, PixelFormat32bppPARGB, black.data());
    const CLSID png = {0x557cf406, 0x1a04, 0x11d3,
                     {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
    IStream* stream = nullptr;
    if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
      if (bitmap.Save(stream, &png, nullptr) == Gdiplus::Ok) {
        STATSTG stats = {};
        HGLOBAL memory = nullptr;
        if (SUCCEEDED(stream->Stat(&stats, STATFLAG_NONAME)) &&
            stats.cbSize.QuadPart <= 1024 * 1024 &&
            SUCCEEDED(GetHGlobalFromStream(stream, &memory))) {
          const auto* start = static_cast<uint8_t*>(GlobalLock(memory));
          if (start) {
            result.assign(start, start + static_cast<size_t>(stats.cbSize.QuadPart));
            GlobalUnlock(memory);
          }
        }
      }
      stream->Release();
    }
  }
  Gdiplus::GdiplusShutdown(token);
  return result;
}

ProcessIcons::ProcessIcons(HWND window) : window_(window), worker_([this] { Run(); }) {}
ProcessIcons::~ProcessIcons() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    requests_.clear();
  }
  ready_.notify_one();
  worker_.join();
}
void ProcessIcons::Request(std::string name, Callback callback) {
  const auto id = ++next_id_;
  callbacks_.emplace(id, std::move(callback));
  {
    std::lock_guard<std::mutex> lock(mutex_);
    requests_.emplace_back(id, std::move(name));
  }
  ready_.notify_one();
}
void ProcessIcons::Complete() {
  std::deque<std::pair<uint64_t, Bytes>> values;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    values.swap(completed_);
  }
  for (auto& item : values) {
    auto callback = callbacks_.find(item.first);
    if (callback != callbacks_.end()) {
      callback->second(std::move(item.second));
      callbacks_.erase(callback);
    }
  }
}
void ProcessIcons::Run() {
  for (;;) {
    std::pair<uint64_t, std::string> request;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      ready_.wait(lock, [this] { return stopping_ || !requests_.empty(); });
      if (stopping_) return;
      request = std::move(requests_.front());
      requests_.pop_front();
    }
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        request.second.c_str(), -1, nullptr, 0);
    Bytes icon;
    if (length > 0 && length < 32768) {
      std::wstring name(length, L'\0');
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, request.second.c_str(),
                          -1, name.data(), length);
      name.resize(length - 1);
      icon = Read(name);
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      completed_.emplace_back(request.first, std::move(icon));
    }
    PostMessageW(window_, kReadyMessage, 0, 0);
  }
}
