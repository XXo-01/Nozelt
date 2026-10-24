#ifndef NOZELT_PROCESS_ICONS_H_
#define NOZELT_PROCESS_ICONS_H_

#include <windows.h>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Extraction stays off the window/Flutter thread. Completion callbacks run only
// on the window thread; shutdown joins the worker before destroying the host.
class ProcessIcons {
 public:
  static constexpr UINT kReadyMessage = WM_APP + 2;
  using Bytes = std::vector<uint8_t>;
  using Callback = std::function<void(Bytes)>;
  explicit ProcessIcons(HWND window);
  ~ProcessIcons();
  void Request(std::string name, Callback callback);
  void Complete();
  static Bytes Read(const std::wstring& process);

 private:
  void Run();
  HWND window_;
  std::mutex mutex_;
  std::condition_variable ready_;
  bool stopping_ = false;
  uint64_t next_id_ = 0;
  std::deque<std::pair<uint64_t, std::string>> requests_;
  std::deque<std::pair<uint64_t, Bytes>> completed_;
  std::map<uint64_t, Callback> callbacks_;
  std::thread worker_;
};
#endif
