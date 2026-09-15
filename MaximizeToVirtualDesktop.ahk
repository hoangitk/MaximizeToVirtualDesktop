; Purpose:
; Bring macOS's green-button "maximize to full-screen virtual desktop"
; behavior to Windows 11.
; When triggered, the foreground window is moved to a brand-new virtual desktop
; and maximized. Closing, un-maximizing, or toggling the hotkey again restores
; everything — the window returns to its original desktop and size, and the
; temporary desktop is removed.
;
#Requires AutoHotkey v2.0
#SingleInstance Force

Persistent

; Without per-monitor DPI awareness, mouse coordinates get virtualized/scaled
; and no longer line up with the physical pixels WM_NCHITTEST expects, so
; small non-client hit targets like the maximize button are missed.
DllCall("SetProcessDpiAwarenessContext", "Ptr", -4, "Int")

; Path to the DLL, relative to this file (also works when this file is included)
; Credit: https://github.com/Ciantic/VirtualDesktopAccessor/blob/rust/example.ah2
VDA_DIR := ""
SplitPath(A_LineFile, , &VDA_DIR)
VDA_PATH := VDA_DIR . "\VirtualDesktopAccessor.dll"
hVirtualDesktopAccessor := DllCall("LoadLibrary", "Str", VDA_PATH, "Ptr")

GetDesktopCountProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetDesktopCount", "Ptr")
GoToDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GoToDesktopNumber", "Ptr")
GetCurrentDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetCurrentDesktopNumber", "Ptr")
IsWindowOnCurrentVirtualDesktopProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "IsWindowOnCurrentVirtualDesktop", "Ptr")
IsWindowOnDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "IsWindowOnDesktopNumber", "Ptr")
MoveWindowToDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "MoveWindowToDesktopNumber", "Ptr")
IsPinnedWindowProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "IsPinnedWindow", "Ptr")
GetDesktopNameProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetDesktopName", "Ptr")
SetDesktopNameProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "SetDesktopName", "Ptr")
CreateDesktopProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "CreateDesktop", "Ptr")
RemoveDesktopProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "RemoveDesktop", "Ptr")

; On change listeners
RegisterPostMessageHookProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "RegisterPostMessageHook", "Ptr")
UnregisterPostMessageHookProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "UnregisterPostMessageHook", "Ptr")

mapTracking := Map()

; Low-level mouse hook detects Shift+Click on a window's maximize button.
; Works wherever Windows 11 Snap Layouts works (apps that return HTMAXBUTTON
; from WM_NCHITTEST). OnMessage/hotkeys can't see clicks on other processes'
; non-client areas, so a real WH_MOUSE_LL hook is required.
; Credit: https://github.com/shanselman/MaximizeToVirtualDesktop/blob/master/src/MaximizeToVirtualDesktop/MaximizeButtonHook.cs
WH_MOUSE_LL := 14
WM_LBUTTONDOWN := 0x0201
WM_NCHITTEST := 0x0084
HTMAXBUTTON := 9
SMTO_ABORTIFHUNG := 0x0002
VK_SHIFT := 0x10

hMouseHook := 0
MouseHookProc := CallbackCreate(LowLevelMouseProc, "F", 3)
hMouseHook := DllCall("SetWindowsHookEx", "Int", WH_MOUSE_LL, "Ptr", MouseHookProc, "Ptr", DllCall("GetModuleHandle", "Ptr", 0, "Ptr"), "UInt", 0, "Ptr")
OnExit(Cleanup)


LowLevelMouseProc(nCode, wParam, lParam) {
    global WM_LBUTTONDOWN, VK_SHIFT, hMouseHook
    if (nCode >= 0 && wParam = WM_LBUTTONDOWN && (DllCall("GetAsyncKeyState", "Int", VK_SHIFT, "Short") & 0x8000)) {
        x := NumGet(lParam, 0, "Int")
        y := NumGet(lParam, 4, "Int")
        ptRaw := NumGet(lParam, 0, "Int64") ; POINT packed as one 64-bit value for WindowFromPoint
        hwnd := DllCall("WindowFromPoint", "Int64", ptRaw, "Ptr")
        if (hwnd && IsClickOnMaximizeButton(hwnd, x, y)) {
            topLevel := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") ; GA_ROOT
            if topLevel {
                SetTimer(HandleMacOSGreenButton.Bind(topLevel), -1) ; defer out of the hook callback
                return 1 ; suppress the click so Windows doesn't also do its normal maximize
            }
        }
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

IsClickOnMaximizeButton(hwnd, x, y) {
    global WM_NCHITTEST, HTMAXBUTTON, SMTO_ABORTIFHUNG
    htLParam := (y & 0xFFFF) << 16 | (x & 0xFFFF)
    ok := DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", WM_NCHITTEST, "Ptr", 0, "Ptr", htLParam, "UInt", SMTO_ABORTIFHUNG, "UInt", 100, "Ptr*", &result := 0, "Ptr")
    return ok != 0 && result = HTMAXBUTTON
}

HandleMacOSGreenButton(hwnd) {
    global GetCurrentDesktopNumberProc, CreateDesktopProc, MoveWindowToDesktopNumberProc, GoToDesktopNumberProc, SetDesktopNameProc, mapTracking

    ;Logic: Cur VT > New VT > Move > Go to New VT
    cur := DllCall(GetCurrentDesktopNumberProc, "Int")
    newNum := DllCall(CreateDesktopProc, "Int")
    DllCall(MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", newNum, "Int")
    DllCall(GoToDesktopNumberProc, "Int", newNum, "Int")

    ; Tracking
    mapTracking[hwnd] := { orig: cur, new: newNum }
    SetTimer(WinMaximize.Bind(hwnd), -300)

    ; Virtual Desktop title
    appName := WinGetProcessName(hwnd)
    winTitle := WinGetTitle(hwnd)
    vdTitle := SubStr(appName " - " winTitle, 1, 50)
    utf8Buf := Buffer(StrPut(vdTitle, "UTF-8"))
    StrPut(vdTitle, utf8Buf, "UTF-8")
    DllCall(SetDesktopNameProc, "Int", newNum, "Ptr", utf8Buf, "Int")
}

SetTimer(CheckWindows, 1000)

CheckWindows() {
    ; WS_MAXIMIZE = 0x01000000
    global IsWindowOnCurrentVirtualDesktopProc, mapTracking
    for hwnd, info in mapTracking.Clone() {
        if !DllCall("IsWindow", "Ptr", hwnd, "Int") {
            RestoreWindow(hwnd, info)
            continue
        }
        if !DllCall(IsWindowOnCurrentVirtualDesktopProc, "Ptr", hwnd, "Int") {
            continue
        }
        if 0x01000000 & WinGetStyle(hwnd) {
            continue
        }
        RestoreWindow(hwnd, info)
    }
}

; Moves the window back to its original desktop and removes the temporary one.
RestoreWindow(hwnd, info) {
    global MoveWindowToDesktopNumberProc, GoToDesktopNumberProc, RemoveDesktopProc, mapTracking
    if WinExist("ahk_id " hwnd) {
        DllCall(MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", info.orig, "Int")
        DllCall(GoToDesktopNumberProc, "Int", info.orig, "Int")
    }
    DllCall(RemoveDesktopProc, "Int", info.new, "Int", info.orig, "Int")
    mapTracking.Delete(hwnd)
}

RestoreAll(*) {
    global mapTracking
    for hwnd, info in mapTracking.Clone()
        RestoreWindow(hwnd, info)
}

ExitAndRestoreAll(*) {
    RestoreAll()
    ExitApp()
}

Cleanup(*) {
    global hMouseHook
    if hMouseHook {
        DllCall("UnhookWindowsHookEx", "Ptr", hMouseHook)
        hMouseHook := 0
    }
}

;@region Hotkey
; Ctrl+Alt+Shift+X
;^!+x:: ToggleForegroundWindow()

; Win+Shift+Enter
#+Enter:: ToggleForegroundWindow()

ToggleForegroundWindow() {
    global mapTracking
    hwnd := WinExist("A")
    if !hwnd {
        return
    }
    if mapTracking.Has(hwnd) {
        RestoreWindow(hwnd, mapTracking[hwnd])
        return
    }
    HandleMacOSGreenButton(hwnd)
}
;@endregion

;@region Tray Menu
TraySetIcon(A_ScriptDir "\app.ico")
A_IconTip := "Maximize to Virtual Desktop"

A_TrayMenu.Delete()
; A_TrayMenu.Add("Ctrl + Alt + Shift + X", (*) => {})
A_TrayMenu.Add("Win + Shift + Enter", (*) => {})
A_TrayMenu.Add("Restore All", RestoreAll)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", ExitAndRestoreAll)
A_TrayMenu.Default := "Restore All" ; double-clicking the tray icon restores instead of exiting

; Set Icon
try {
    A_TrayMenu.SetIcon("Win + Shift + Enter", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Restore All", "imageres.dll", 230)  ; Icon 🔄️
    A_TrayMenu.SetIcon("Exit", "shell32.dll", 220)          ; Icon 🚫
}
;@endregion
