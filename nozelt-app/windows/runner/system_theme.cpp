#include "system_theme.h"

namespace {
enum class PreferredAppMode { Default, AllowDark, ForceDark, ForceLight, Max };
using SetAppMode = PreferredAppMode(WINAPI*)(PreferredAppMode);
using AllowWindow = bool(WINAPI*)(HWND, bool);
using RefreshPolicy = void(WINAPI*)();
using FlushMenus = void(WINAPI*)();

struct MenuTheme {
  SetAppMode set_mode = nullptr;
  AllowWindow allow_window = nullptr;
  RefreshPolicy refresh = nullptr;
  FlushMenus flush = nullptr;

  MenuTheme() {
    // Ordinal 135 had a different signature before Windows 10 1903.
    // Probe the actual OS version before using these optional exports.
    using GetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
    auto get_version = reinterpret_cast<GetVersion>(GetProcAddress(
        GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
    OSVERSIONINFOW version = {};
    version.dwOSVersionInfoSize = sizeof(version);
    if (!get_version || get_version(&version) != 0 ||
        version.dwMajorVersion != 10 || version.dwBuildNumber < 18362) return;
    HMODULE theme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!theme) return;
    // Same OS theme opt-in used by Microsoft PowerToys (ZoomIt Utility.cpp).
    // These exports are private: missing support falls back to a normal menu.
    set_mode = reinterpret_cast<SetAppMode>(GetProcAddress(theme, MAKEINTRESOURCEA(135)));
    allow_window = reinterpret_cast<AllowWindow>(GetProcAddress(theme, MAKEINTRESOURCEA(133)));
    refresh = reinterpret_cast<RefreshPolicy>(GetProcAddress(theme, MAKEINTRESOURCEA(104)));
    flush = reinterpret_cast<FlushMenus>(GetProcAddress(theme, MAKEINTRESOURCEA(136)));
    // Keep the system DLL loaded for this process's lifetime.
  }
};
}

void RefreshSystemMenuTheme(HWND owner) {
  static MenuTheme theme;
  HIGHCONTRASTW contrast = {};
  contrast.cbSize = sizeof(contrast);
  SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0);
  const bool high_contrast = (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
  if (theme.refresh) theme.refresh();
  // AllowDark follows AppsUseLightTheme; never change the user's OS setting.
  if (theme.set_mode) theme.set_mode(high_contrast ? PreferredAppMode::Default : PreferredAppMode::AllowDark);
  if (theme.allow_window) theme.allow_window(owner, !high_contrast);
  if (theme.flush) theme.flush();
}
