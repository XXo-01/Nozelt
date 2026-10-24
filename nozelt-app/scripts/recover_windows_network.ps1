[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this recovery script as administrator.'
}
if (Get-Process -Name nozelt -ErrorAction SilentlyContinue) {
    throw 'Close Nozelt before releasing its network protection.'
}
# Uses only stock Windows APIs. No Nozelt EXE/DLL, Defender exception, DNS,
# route, adapter or Windows Firewall reset is required.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NozeltNetworkRecovery {
  [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineOpen0(IntPtr server, uint authn, IntPtr identity, IntPtr session, out IntPtr handle);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineClose0(IntPtr handle);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionBegin0(IntPtr handle, uint flags);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionCommit0(IntPtr handle);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionAbort0(IntPtr handle);
  [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterDeleteByKey0(IntPtr handle, ref Guid key);
  static void Check(uint code) { if(code != 0) throw new InvalidOperationException("WFP operation failed: 0x" + code.ToString("X8")); }
  public static void Release() {
    IntPtr engine;
    Check(FwpmEngineOpen0(IntPtr.Zero, 10, IntPtr.Zero, IntPtr.Zero, out engine));
    try {
      Check(FwpmTransactionBegin0(engine,0));
      try {
        for(ushort index=0;index<512;index++) {
          var key=new Guid(0xa0d4ec71,0x0967,0x49a0,0x9e,0x04,0xf7,0x1a,0x19,0x6b,(byte)(index>>8),(byte)index);
          uint result=FwpmFilterDeleteByKey0(engine,ref key);
          if(result!=0x80320003) Check(result); // FWP_E_FILTER_NOT_FOUND
        }
        Check(FwpmTransactionCommit0(engine));
      } finally { FwpmTransactionAbort0(engine); }
    } finally { FwpmEngineClose0(engine); }
  }
}
'@
[NozeltNetworkRecovery]::Release()
Write-Output 'Only Nozelt network protection has been released.'
