#include "flutter_window.h"

#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "system_theme.h"
#include "startup_task.h"

namespace {

constexpr wchar_t kThemeRegistryKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr wchar_t kSystemThemeRegistryValue[] = L"SystemUsesLightTheme";
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayMenuOpen = 40001;
constexpr UINT kTrayMenuToggle = 40002;
constexpr UINT kTrayMenuExit = 40003;
constexpr UINT kTrayMenuRestart = 40004;
constexpr UINT kTrayMenuRules = 40005;
constexpr UINT kTrayMenuGlobal = 40006;
constexpr char kShellChannelName[] = "dev.nozelt.nozelt/windows_shell";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  RefreshSystemMenuTheme(GetHandle());

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  process_icons_ = std::make_unique<ProcessIcons>(GetHandle());
  CreateShellChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  process_icons_.reset();
  RemoveTrayIcon();
  shell_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case ProcessIcons::kReadyMessage:
      if (process_icons_) process_icons_->Complete();
      return 0;
    case WM_CLOSE:
      if (!exiting_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      RECT minimum = {0, 0, MulDiv(720, dpi, 96), MulDiv(520, dpi, 96)};
      AdjustWindowRectExForDpi(&minimum,
          static_cast<DWORD>(GetWindowLongPtrW(hwnd, GWL_STYLE)), FALSE,
          static_cast<DWORD>(GetWindowLongPtrW(hwnd, GWL_EXSTYLE)), dpi);
      info->ptMinTrackSize.x = minimum.right - minimum.left;
      info->ptMinTrackSize.y = minimum.bottom - minimum.top;
      return 0;
    }
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
          if (tray_click_action_ == "toggle_tun") {
            ToggleFromTray();
          } else {
            ShowMainWindow();
          }
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
      }
      break;
    case WM_SETTINGCHANGE:
      RefreshSystemMenuTheme(hwnd);
      RefreshTrayIcon();
      break;
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::CreateShellChannel() {
  shell_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kShellChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  shell_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getProcessIcon") {
          const auto* name = std::get_if<std::string>(call.arguments());
          if (!name || name->size() > 1024 || !process_icons_) {
            result->Success();
            return;
          }
          auto pending = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
              std::move(result));
          process_icons_->Request(*name, [pending](ProcessIcons::Bytes bytes) {
            if (bytes.empty()) pending->Success();
            else pending->Success(flutter::EncodableValue(std::move(bytes)));
          });
          return;
        }
        if (call.method_name() == "setState") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            const auto mode = arguments->find(flutter::EncodableValue("routingMode"));
            if (mode != arguments->end()) {
              if (const auto* value = std::get_if<std::string>(&mode->second))
                routing_mode_ = *value == "global" ? "global" : "rule";
            }
            const auto connected =
                arguments->find(flutter::EncodableValue("connected"));
            if (connected != arguments->end()) {
              if (const auto* value = std::get_if<bool>(&connected->second)) {
                tun_connected_ = *value;
              }
            }
            const auto click_action =
                arguments->find(flutter::EncodableValue("clickAction"));
            const auto protection = arguments->find(flutter::EncodableValue("protectionActive"));
            if (protection != arguments->end()) {
              if (const auto* value = std::get_if<bool>(&protection->second)) {
                protection_active_ = *value;
              }
            }
            if (click_action != arguments->end()) {
              if (const auto* value =
                      std::get_if<std::string>(&click_action->second)) {
                tray_click_action_ = *value;
              }
            }
            const auto language_code =
                arguments->find(flutter::EncodableValue("languageCode"));
            if (language_code != arguments->end()) {
              if (const auto* value =
                      std::get_if<std::string>(&language_code->second)) {
                language_code_ = *value == "ru" ? "ru" : "en";
              }
            }
          }
          RefreshTrayIcon();
          result->Success();
          return;
        }
        if (call.method_name() == "showWindow") {
          ShowMainWindow();
          result->Success();
          return;
        }
        if (call.method_name() == "requestExit") {
          result->Success();
          RequestExit();
          return;
        }
        if (call.method_name() == "configureStartup") {
          const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) { result->Error("bad_args", "Startup settings required"); return; }
          const auto enabled = arguments->find(flutter::EncodableValue("enabled"));
          const auto silent = arguments->find(flutter::EncodableValue("silent"));
          if (enabled == arguments->end() || silent == arguments->end() ||
              !std::holds_alternative<bool>(enabled->second) || !std::holds_alternative<bool>(silent->second)) {
            result->Error("bad_args", "Startup settings required"); return;
          }
          if (FAILED(ConfigureStartupTask(std::get<bool>(enabled->second), std::get<bool>(silent->second))))
            result->Error("startup_failed", "Could not configure Windows logon task");
          else result->Success();
          return;
        }
        if (call.method_name() == "requestRestart") {
          bool resume = false;
          if (const auto args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto item = args->find(flutter::EncodableValue("resumeTun"));
            if (item != args->end()) {
              if (const auto value = std::get_if<bool>(&item->second)) resume = *value;
            }
          }
          if (RequestRestart(resume)) { result->Success(); RequestExit(); }
          else result->Error("restart_failed", "Could not restart Nozelt");
          return;
        }
        result->NotImplemented();
      });
}

bool FlutterWindow::SystemUsesLightTheme() const {
  DWORD light_theme = 1;
  DWORD size = sizeof(light_theme);
  const auto status =
      RegGetValueW(HKEY_CURRENT_USER, kThemeRegistryKey,
                   kSystemThemeRegistryValue, RRF_RT_REG_DWORD, nullptr,
                   &light_theme, &size);
  return status != ERROR_SUCCESS || light_theme != 0;
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_ || GetHandle() == nullptr) {
    return;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  wcscpy_s(tray_icon_.szTip, L"Nozelt \u2014 TUN disabled");
  RefreshTrayIcon();
  tray_icon_added_ =
      Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_icon_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::RefreshTrayIcon() {
  const int icon_id = tun_connected_
                          ? IDI_TRAY_CONNECTED
                          : (SystemUsesLightTheme()
                                 ? IDI_TRAY_DISCONNECTED_BLACK
                                 : IDI_TRAY_DISCONNECTED_WHITE);
  tray_icon_.hIcon = static_cast<HICON>(
      LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(icon_id),
                 IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                 GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  if (language_code_ == "ru") {
    wcscpy_s(tray_icon_.szTip,
             tun_connected_
                 ? L"Nozelt \u2014 TUN \u0432\u043A\u043B\u044E\u0447\u0451\u043D"
                 : L"Nozelt \u2014 TUN \u0432\u044B\u043A\u043B\u044E\u0447\u0435\u043D");
  } else {
    wcscpy_s(tray_icon_.szTip,
             tun_connected_ ? L"Nozelt \u2014 TUN enabled"
                            : L"Nozelt \u2014 TUN disabled");
  }
  if (protection_active_ && !tun_connected_) {
    wcscpy_s(tray_icon_.szTip, language_code_ == "ru"
        ? L"Nozelt — защита сети включена, VPN не подключён"
        : L"Nozelt — network protected, VPN disconnected");
  }
  if (tray_icon_added_) {
    tray_icon_.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
    tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  }
}

void FlutterWindow::ShowMainWindow() {
  if (GetHandle() == nullptr) {
    return;
  }
  if (IsIconic(GetHandle())) {
    ShowWindow(GetHandle(), SW_RESTORE);
  } else {
    ShowWindow(GetHandle(), SW_SHOW);
  }
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ToggleFromTray() {
  if (shell_channel_) {
    shell_channel_->InvokeMethod(
        "trayToggleRequested",
        std::make_unique<flutter::EncodableValue>());
  }
}

void FlutterWindow::ShowTrayMenu() {
  RefreshSystemMenuTheme(GetHandle());
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  const bool russian = language_code_ == "ru";
  AppendMenuW(
      menu, MF_STRING, kTrayMenuOpen,
      russian ? L"Показать окно" : L"Show window");
  AppendMenuW(
      menu, MF_STRING, kTrayMenuToggle,
      russian
          ? ((tun_connected_ || protection_active_)
                 ? L"\u0412\u044B\u043A\u043B\u044E\u0447\u0438\u0442\u044C TUN"
                 : L"\u0412\u043A\u043B\u044E\u0447\u0438\u0442\u044C TUN")
          : ((tun_connected_ || protection_active_) ? L"Disable TUN" : L"Enable TUN"));
  HMENU modes = CreatePopupMenu();
  if (modes != nullptr) {
    AppendMenuW(modes, MF_STRING | (routing_mode_ == "global" ? MF_CHECKED : 0),
      kTrayMenuGlobal, russian ? L"Глобально" : L"Global");
    AppendMenuW(modes, MF_STRING | (routing_mode_ == "rule" ? MF_CHECKED : 0),
      kTrayMenuRules, russian ? L"Правила" : L"Rules");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(modes),
      russian ? L"Режим маршрутизации" : L"Routing mode");
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayMenuRestart,
    russian ? L"Перезапустить приложение" : L"Restart application");
  AppendMenuW(menu, MF_STRING, kTrayMenuExit,
              russian ? L"Выйти из приложения" : L"Exit application");

  POINT cursor = {};
  GetCursorPos(&cursor);
  SetForegroundWindow(GetHandle());
  const UINT selected =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                     cursor.x, cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessageW(GetHandle(), WM_NULL, 0, 0);

  switch (selected) {
    case kTrayMenuOpen:
      ShowMainWindow();
      break;
    case kTrayMenuToggle:
      ToggleFromTray();
      break;
    case kTrayMenuRules:
    case kTrayMenuGlobal:
      if (shell_channel_) shell_channel_->InvokeMethod("trayRoutingModeRequested",
        std::make_unique<flutter::EncodableValue>(selected == kTrayMenuGlobal ? "global" : "rule"));
      break;
    case kTrayMenuRestart:
      if (shell_channel_) shell_channel_->InvokeMethod("trayRestartRequested",
        std::make_unique<flutter::EncodableValue>());
      break;
    case kTrayMenuExit:
      if (shell_channel_) {
        shell_channel_->InvokeMethod(
            "trayExitRequested",
            std::make_unique<flutter::EncodableValue>());
      } else {
        RequestExit();
      }
      break;
  }
}

bool FlutterWindow::RequestRestart(bool resume_tun) {
  std::wstring executable(32768, L'\0');
  const DWORD count = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (count == 0 || count >= executable.size()) return false;
  executable.resize(count);
  std::wstring command = L"\"" + executable + L"\" --restart-wait=" + std::to_wstring(GetCurrentProcessId());
  if (!IsWindowVisible(GetHandle())) command += L" --silent";
  if (resume_tun) command += L" --connect-once";
  STARTUPINFOW startup = {}; startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  const std::wstring directory = executable.substr(0, executable.find_last_of(L"\\/"));
  // Dart reads this variable, not the command line, to reconnect at start.
  // The child inherits the environment; ours is restored right after.
  if (resume_tun) SetEnvironmentVariableW(L"NOZELT_CONNECT_ON_START", L"1");
  const BOOL started = CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
      nullptr, directory.c_str(), &startup, &process);
  if (resume_tun) SetEnvironmentVariableW(L"NOZELT_CONNECT_ON_START", nullptr);
  if (!started) return false;
  CloseHandle(process.hThread); CloseHandle(process.hProcess);
  return true;
}

void FlutterWindow::RequestExit() {
  exiting_ = true;
  SetQuitOnClose(true);
  Destroy();
}
