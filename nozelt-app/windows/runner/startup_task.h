#pragma once
#include <windows.h>

// Per-user interactive logon task. Wintun requires the highest available token.
// No password is stored and no task is registered until the user enables it.
HRESULT ConfigureStartupTask(bool enabled, bool silent);
