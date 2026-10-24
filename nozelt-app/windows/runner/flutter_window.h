#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"
#include "process_icons.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project, bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void CreateShellChannel();
  void AddTrayIcon();
  void RemoveTrayIcon();
  void RefreshTrayIcon();
  void ShowMainWindow();
  void ToggleFromTray();
  void ShowTrayMenu();
  void RequestExit();
  bool RequestRestart(bool resume_tun);
  bool SystemUsesLightTheme() const;

  // The project to run.
  flutter::DartProject project_;
  std::unique_ptr<ProcessIcons> process_icons_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      shell_channel_;
  NOTIFYICONDATAW tray_icon_ = {};
  UINT taskbar_created_message_ = 0;
  bool tray_icon_added_ = false;
  bool tun_connected_ = false;
  bool protection_active_ = false;
  bool exiting_ = false;
  bool start_hidden_ = false;
  std::string routing_mode_ = "rule";
  std::string tray_click_action_ = "open_window";
  std::string language_code_ = "en";
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
