#include "../windows/runner/process_icons.h"
#include <fstream>
#include <iostream>

int wmain() {
  if (!ProcessIcons::Read(L"\\\\server\\file.exe").empty() ||
      !ProcessIcons::Read(L"nozelt-missing-process.exe").empty()) return 1;
  auto icon = ProcessIcons::Read(L"explorer.exe");
  if (icon.size() < 8 || icon[0] != 137 || icon[1] != 80) return 2;
  std::ofstream file("build/process_explorer.png", std::ios::binary);
  file.write(reinterpret_cast<const char*>(icon.data()), icon.size());
  file.close();
  // GDI+ may initialize process-wide caches during the first extraction.
  const DWORD before = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
  for (int index = 0; index < 32; ++index)
    if (ProcessIcons::Read(L"explorer.exe").empty()) return 3;
  const DWORD after = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
  std::cout << "GDI objects after warm-up: " << before << " -> " << after << "\n";
  if (after > before + 2) return 4;
  HWND window = CreateWindowExW(0, L"STATIC", L"Nozelt icon test", 0,
      0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr);
  if (!window) return 5;
  int completed = 0;
  {
    ProcessIcons worker(window);
    worker.Request("explorer.exe", [&](ProcessIcons::Bytes bytes) {
      if (!bytes.empty()) ++completed;
    });
    const auto deadline = GetTickCount64() + 10000;
    while (!completed && GetTickCount64() < deadline) {
      MSG message;
      while (PeekMessageW(&message, window, 0, 0, PM_REMOVE)) {
        if (message.message == ProcessIcons::kReadyMessage) worker.Complete();
        else DispatchMessageW(&message);
      }
      Sleep(10);
    }
  }
  DestroyWindow(window);
  if (completed != 1) return 6;
  std::cout << "PNG extraction, missing-process fallback, network-path rejection, "
               "32 repeated extractions without GDI leaks and worker completion passed.\n";
  return 0;
}
