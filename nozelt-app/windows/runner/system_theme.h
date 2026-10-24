#ifndef NOZELT_SYSTEM_THEME_H_
#define NOZELT_SYSTEM_THEME_H_
#include <windows.h>

// Windows draws and measures all menu items. Only opt into its theme.
void RefreshSystemMenuTheme(HWND owner);
#endif
