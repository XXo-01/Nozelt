// Isolated rendering check: no Flutter engine, profiles, VPN, or system settings.
#include <windows.h>
#include <gdiplus.h>
#include <cstdio>
#include <vector>
#include "../windows/runner/system_theme.h"

namespace {
const wchar_t* output_path;
bool captured = false;
BOOL CALLBACK FindPopup(HWND window, LPARAM value) {
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  wchar_t name[32] = {};
  GetClassNameW(window, name, 32);
  if (process == GetCurrentProcessId() && wcscmp(name, L"#32768") == 0 && IsWindowVisible(window)) {
    *reinterpret_cast<HWND*>(value) = window;
    return FALSE;
  }
  return TRUE;
}
void CapturePopup() {
  HWND popup = nullptr;
  EnumWindows(FindPopup, reinterpret_cast<LPARAM>(&popup));
  if (!popup) return;
  RECT bounds;
  GetWindowRect(popup, &bounds);
  HDC dc = GetDC(popup), copy = CreateCompatibleDC(dc);
  HBITMAP bitmap = CreateCompatibleBitmap(dc, bounds.right - bounds.left, bounds.bottom - bounds.top);
  auto previous = SelectObject(copy, bitmap);
  if (PrintWindow(popup, copy, 2)) {
    UINT size = 0, count = 0;
    Gdiplus::GetImageEncodersSize(&count, &size);
    std::vector<BYTE> buffer(size);
    auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
    Gdiplus::GetImageEncoders(count, size, codecs);
    for (UINT i = 0; i < count; ++i) {
      if (wcscmp(codecs[i].MimeType, L"image/png") == 0) {
        Gdiplus::Bitmap image(bitmap, nullptr);
        captured = image.Save(output_path, &codecs[i].Clsid, nullptr) == Gdiplus::Ok;
        break;
      }
    }
  }
  SelectObject(copy, previous);
  DeleteObject(bitmap); DeleteDC(copy); ReleaseDC(popup, dc);
}
LRESULT CALLBACK WindowProc(HWND owner, UINT message, WPARAM param, LPARAM data) {
  if (message == WM_TIMER) {
    CapturePopup();
    KillTimer(owner, 1);
    EndMenu();
    return 0;
  }
  return DefWindowProcW(owner, message, param, data);
}
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  output_path = argv[1];
  SetProcessDPIAware();
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  Gdiplus::GdiplusStartup(&token, &input, nullptr);
  WNDCLASSW type = {};
  type.lpfnWndProc = WindowProc; type.hInstance = GetModuleHandleW(nullptr); type.lpszClassName = L"NozeltMenuSmoke";
  RegisterClassW(&type);
  HWND owner = CreateWindowW(type.lpszClassName, L"Nozelt menu test", WS_OVERLAPPED, 0, 0, 1, 1, nullptr, nullptr, type.hInstance, nullptr);
  RefreshSystemMenuTheme(owner);
  HMENU menu = CreatePopupMenu(), modes = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, 1, L"Показать окно");
  AppendMenuW(menu, MF_STRING, 2, L"Выключить TUN");
  AppendMenuW(modes, MF_STRING, 3, L"Глобально");
  AppendMenuW(modes, MF_STRING | MF_CHECKED, 4, L"Правила");
  AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(modes), L"Режим маршрутизации");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 5, L"Перезапустить приложение");
  AppendMenuW(menu, MF_STRING, 6, L"Выйти из приложения");
  for (int i = 0; i < GetMenuItemCount(menu); ++i) {
    MENUITEMINFOW item = {}; item.cbSize = sizeof(item); item.fMask = MIIM_FTYPE;
    if (!GetMenuItemInfoW(menu, i, TRUE, &item) || (item.fType & MFT_OWNERDRAW)) return 3;
  }
  SetTimer(owner, 1, 350, nullptr);
  TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, 640, 300, 0, owner, nullptr);
  DestroyMenu(menu); DestroyWindow(owner);
  Gdiplus::GdiplusShutdown(token);
  std::puts(captured ? "Native system menu rendered and captured; no owner-draw items." : "Menu capture failed.");
  return captured ? 0 : 4;
}
