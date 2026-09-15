# Maximize To Virtual Desktop

AutoHotkey v2 script ([MaximizeToVirtualDesktop.ahk](MaximizeToVirtualDesktop.ahk)) that brings macOS's green-button "maximize to a new full-screen desktop" behavior to Windows 11.

## Usage

**Shift+Click** a window's maximize button to move it to a brand-new virtual desktop and maximize it; restoring/un-maximizing moves it back and removes the temporary virtual desktop.

## Dev

### Lib

Depends on `VirtualDesktopAccessor.dll` (Ciantic/VirtualDesktopAccessor, Rust-based, Win11-only for `CreateDesktop`/ `MoveDesktop`/ `RemoveDesktop`/`SetDesktopName`).

### Test/run loop

```powershell
Get-Process AutoHotkey* -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" -ArgumentList '"d:\Dev\AHK\MaximizeToVirtualDesktop\MaximizeToVirtualDesktop.ahk"'
```

To check whether the script crashed and auto-restarted (look for a second process
with `/restart` in its command line):

```powershell
Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" | Select-Object ProcessId, CommandLine
```

Cross-check crash details in the Windows Application event log:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'} -MaxEvents 5 |
  Where-Object { $_.Message -like '*AutoHotkey*' } | Select-Object TimeCreated, Message
```

### Key gotchas (learned the hard way)

- **`OnMessage()` cannot see other processes' non-client clicks.** It only receives
  messages sent to the AHK script's own hidden window. Detecting a Shift+click on
  another app's maximize button requires a real global `WH_MOUSE_LL` hook
  (`CallbackCreate(fn, "F", 3)` + `SetWindowsHookEx`), not `OnMessage`/hotkeys.

- **Cross-process maximize-button hit-testing**: in the low-level mouse hook, on
  `WM_LBUTTONDOWN` get `WindowFromPoint`, then
  `SendMessageTimeoutW(hwnd, WM_NCHITTEST, 0, MAKELPARAM(x,y))` and check the result
  is `HTMAXBUTTON` (9). This only works for apps that support Windows 11 Snap
  Layouts. Do heavy work (COM/DLL calls) via `SetTimer(fn.Bind(...), -1)` deferred
  out of the hook callback — never block inside `WH_MOUSE_LL`.
  
  > Greate tips from [shanselman/MaximizeButtonHook.cs](https://github.com/shanselman/MaximizeToVirtualDesktop/blob/master/src/MaximizeToVirtualDesktop/MaximizeButtonHook.cs)

- **Elevated windows (e.g. `regedit`) silently don't respond** to hotkeys/`#HotIf
  WinExist("A")` when this script isn't also elevated — UIPI blocks the
  active-window query. This script must run as Administrator to interact with
  elevated windows; it's a Windows restriction, not a bug to work around.

- **`VirtualDesktopAccessor.dll`'s `SetDesktopName(i32, *const i8)` expects UTF-8
  bytes**, not AHK's native UTF-16 `"Str"` type. Passing `"Str"` directly corrupts
  memory and crashes the DLL (access violation). Must manually encode:
  
  ```ahk
  buf := Buffer(StrPut(s, "UTF-8"))
  StrPut(s, buf, "UTF-8")
  DllCall(proc, "Int", n, "Ptr", buf, "Int")
  ```

- **`MoveWindowToDesktopNumber` alone doesn't switch your view.** You must also call
  `GoToDesktopNumber` (both when moving to the new desktop and when restoring back
  to the original), otherwise the window just silently moves off-screen and it
  looks like nothing happened.

## Credits

- Ideas: [shanselman/MaximizeToVirtualDesktop](https://github.com/shanselman/MaximizeToVirtualDesktop)
- app.icon (https://icon-sets.iconify.design/streamline-flex-color/full-screen-osx/)

## License

MIT

---
