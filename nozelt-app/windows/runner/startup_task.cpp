#include "startup_task.h"

#include <taskschd.h>
#include <sddl.h>
#include <wrl/client.h>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {
struct Bstr {
  explicit Bstr(const std::wstring& text) : value(SysAllocString(text.c_str())) {}
  ~Bstr() { SysFreeString(value); }
  operator BSTR() const { return value; }
  BSTR value;
};
HRESULT UserSid(std::wstring& sid) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    return HRESULT_FROM_WIN32(GetLastError());
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  const BOOL read = GetTokenInformation(token, TokenUser, buffer.data(), size, &size);
  const DWORD error = GetLastError();
  CloseHandle(token);
  if (!read) return HRESULT_FROM_WIN32(error);
  LPWSTR encoded = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &encoded))
    return HRESULT_FROM_WIN32(GetLastError());
  sid = encoded;
  LocalFree(encoded);
  return S_OK;
}
}  // namespace

#define TASK_CHECK(operation) do { const HRESULT hr = (operation); if (FAILED(hr)) return hr; } while (false)

HRESULT ConfigureStartupTask(bool enabled, bool silent) {
  std::wstring sid;
  TASK_CHECK(UserSid(sid));
  Bstr name(L"Nozelt-Portable-" + sid);
  Bstr user(sid);
  VARIANT empty; VariantInit(&empty);
  ComPtr<ITaskService> service;
  TASK_CHECK(CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
    IID_PPV_ARGS(&service)));
  TASK_CHECK(service->Connect(empty, empty, empty, empty));
  ComPtr<ITaskFolder> folder;
  TASK_CHECK(service->GetFolder(Bstr(L"\\"), &folder));
  if (!enabled) {
    const HRESULT hr = folder->DeleteTask(name, 0);
    return hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ? S_OK : hr;
  }

  std::vector<wchar_t> path(32768);
  const DWORD count = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (count == 0 || count >= path.size()) return E_FAIL;
  const std::wstring executable(path.data(), count);
  const std::wstring directory = executable.substr(0, executable.find_last_of(L"\\/"));
  ComPtr<ITaskDefinition> task;
  TASK_CHECK(service->NewTask(0, &task));
  ComPtr<IPrincipal> principal;
  TASK_CHECK(task->get_Principal(&principal));
  TASK_CHECK(principal->put_UserId(user));
  TASK_CHECK(principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN));
  TASK_CHECK(principal->put_RunLevel(TASK_RUNLEVEL_HIGHEST));
  ComPtr<ITaskSettings> settings;
  TASK_CHECK(task->get_Settings(&settings));
  TASK_CHECK(settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE));
  TASK_CHECK(settings->put_StopIfGoingOnBatteries(VARIANT_FALSE));
  TASK_CHECK(settings->put_ExecutionTimeLimit(Bstr(L"PT0S")));
  TASK_CHECK(settings->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW));
  ComPtr<ITriggerCollection> triggers;
  TASK_CHECK(task->get_Triggers(&triggers));
  ComPtr<ITrigger> trigger;
  TASK_CHECK(triggers->Create(TASK_TRIGGER_LOGON, &trigger));
  ComPtr<ILogonTrigger> logon;
  TASK_CHECK(trigger.As(&logon));
  TASK_CHECK(logon->put_UserId(user));
  TASK_CHECK(logon->put_Delay(Bstr(L"PT10S")));
  ComPtr<IActionCollection> actions;
  TASK_CHECK(task->get_Actions(&actions));
  ComPtr<IAction> action;
  TASK_CHECK(actions->Create(TASK_ACTION_EXEC, &action));
  ComPtr<IExecAction> execute;
  TASK_CHECK(action.As(&execute));
  TASK_CHECK(execute->put_Path(Bstr(executable)));
  TASK_CHECK(execute->put_WorkingDirectory(Bstr(directory)));
  TASK_CHECK(execute->put_Arguments(Bstr(silent ? L"--startup --silent" : L"--startup")));
  VARIANT identity; VariantInit(&identity);
  identity.vt = VT_BSTR; identity.bstrVal = user.value;
  ComPtr<IRegisteredTask> registered;
  TASK_CHECK(folder->RegisterTaskDefinition(name, task.Get(), TASK_CREATE_OR_UPDATE,
    identity, empty, TASK_LOGON_INTERACTIVE_TOKEN, empty, &registered));
  return S_OK;
}
