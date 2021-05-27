;
; Window Spy
;

; #NoTrayIcon
#SingleInstance Ignore
SetWorkingDir A_ScriptDir
; SetBatchLines -1
CoordMode "Pixel", "Screen"

WinGetTextFast(window, detect_hidden) {
    ; WinGetText ALWAYS uses the "fast" mode - TitleMatchMode only affects
    ; WinText/ExcludeText parameters.  In Slow mode, GetWindowText() is used
    ; to retrieve the text of each control.
    try {
        controls := WinGetControlsHwnd(window)
    } catch TargetError as e {
        return "Get controls fail: " e.Message
    }
    static WINDOW_TEXT_SIZE := 32767 ; Defined in AutoHotkey source.
    buf := Buffer(WINDOW_TEXT_SIZE * 2) ; *2 for Unicode
    local text := ""
    for control in controls
    {
        if !detect_hidden && !DllCall("IsWindowVisible", "ptr", control)
            continue
        if !DllCall("GetWindowText", "ptr", control, "ptr", buf, "int", WINDOW_TEXT_SIZE)
            continue
        text .= StrGet(buf) . "`n"
    }
    return text
}

ScreenToClientPos(hWnd, &x, &y) {
    try {
        WinGetPos(&wX, &wY,,, hWnd)
    } catch TargetError {
        return false
    }
    x += wX
    y += wY
    pt := Buffer(8)
    NumPut("int", x, "int", y, pt)
    if !DllCall("ScreenToClient", "ptr", hWnd, "ptr", pt)
        return false
    x := NumGet(pt, 0, "int")
    y := NumGet(pt, 4, "int")
    return true
}

textMangle(text) {
    elli := false
    pos := InStr(text, "`n")
    if (pos) {
        text := SubStr(text, 1, pos-1)
        elli := true
    }
    if (StrLen(text) > 40) {
        text := SubStr(text, 1, 40)
        elli := true
    }
    if (elli) 
        text .= " …"
    return text
}

GetMouseInfo() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&msX, &msY)
    CoordMode "Mouse", "Window"
    MouseGetPos(&mrX, &mrY)
    CoordMode "Mouse", "Client"
    MouseGetPos(&mcX, &mcY)
    return (
        "Screen:`t" msX ", " msY "`n"
        "Window:`t" mrX ", " mrY "`n"
        "Client:`t" mcX ", " mcY "`n"
        "Color:`t#" SubStr(PixelGetColor(msX, msY), 3)
    )
}

GetWindowInfo(window) {
    try {
        return (
            WinGetTitle(window) "`n"
            "ahk_class " WinGetClass(window)  "`n"
            "ahk_exe " WinGetProcessName(window)  "`n"
            "ahk_pid " WinGetPID(window)
        )
    } catch TargetError as e {
        return "Get window info fail: " e.Message
    }
}

GetWindowPosInfo(window) {
    try {
        WinGetPos(&wX, &wY, &wW, &wH, window)
        WinGetClientPos(&wcX, &wcY, &wcW, &wcH, window)
        return (
            "`tX: " wX 
            "`tY: " wY 
            "`tW: " wW 
            "`tH: " wH 
            "`nClient:`tX: " wcX "`tY: " wcY "`tW: " wcW "`tH: " wcH
        )
    } catch TargetError as e {
        return "Get window position fail: " e.Message
    }
}

GetStatusBarText(window) {
    text := ""
    loop {
        try {
            text .= "[" A_Index "]`t" textMangle(StatusBarGetText(A_Index, window)) "`n"
        } catch as e {
            break
        }
    }
    return SubStr(text, 1, -1)
}

GetControlInfo(window, control) {
    try {
        ControlGetPos(&screenX, &screenY, &screenWidth, &screenHeight, control)
        clientX := screenX
        clientY := screenY
        ScreenToClientPos(window, &clientX, &clientY)
        WinGetClientPos(,, &clientWidth, &clientHeight, ControlGetHwnd(control))
        return (
            "ClassNN:`t" ControlGetClassNN(control) "`n"
            "Text:`t" textMangle(ControlGetText(control)) "`n"
            "Screen:`tX: " screenX "`tY: " screenY "`tW: " screenWidth "`tH: " screenHeight "`n"
            "Client:`tX: " clientX "`tY: " clientY "`tW: " clientWidth "`tH: " clientHeight
        )
    } catch TargetError as e {
        return "Get control info fail: " e.Message
    }
}

GetVisibleText(window, slowMode) {
    if slowMode {
        try {
            DetectHiddenText(False)
            return WinGetText(window)
        } catch TargetError as e {
            return "Get visible text fail: " e.Message
        }
    } else {
        return WinGetTextFast(window, false)
    }
}

GetAllText(window, slowMode) {
    if slowMode {
        try {
            DetectHiddenText(True)
            return WinGetText(window)
        } catch TargetError as e {
            return "Get text fail: " e.Message
        }
    } else {
        return WinGetTextFast(window, true)
    }
}

class MainWindow {
    window := 0
    control := 0
    textCache := Map()
    autoUpdateEnabled := false

    textList := Map(
        "NotFrozen", "Updating...",
        "Frozen", "Update suspended",
        "MouseCtrl", "Control Under Mouse Position",
        "FocusCtrl", "Focused Control",
    )

    OnOptionUpdateChange(*) {
        this.updateAutoUpdateTimer()
    }

    OnOptionAlwaysOnTopChanged(checkbox, *) {
        this.gui.opt(
            (checkbox.value ? "+" : "-")
            "AlwaysOnTop"
        )
    }

    OnOptionTargetChange(*) {
        this.SetText(
            "CtrlLabel", 
            this.textList[this.gui["GetCursor"].value ? "MouseCtrl" : "FocusCtrl"] ":"
        )
    }

    OnResize(window, minMax, width, height) {
        ; Stop auto update when minimize
        if (minMax == -1) {
            this.autoUpdate(false)
        } else {
            this.autoUpdate(true)
        }

        list := "Title,MousePos,Ctrl,Pos,SBText,VisText,AllText,Options"
        loop parse list, "," {
            window[A_LoopField].move(,,width - window.marginX*2)
        }
    }

    OnClose(window) {
        ExitApp
    }

    __New() {
        this.gui := Gui("+AlwaysOnTop +Resize +DPIScale MinSize")
        this.gui.add("Text", "xm", "Window Title, Class and Process:")
        this.gui.add("Edit", "xm w320 r4 ReadOnly -Wrap vTitle")
        this.gui.add("Text",, "Mouse Position:")
        this.gui.add("Edit", "w320 r4 ReadOnly -Wrap vMousePos")
        this.gui.add("Text", "w320 vCtrlLabel", this.textList["FocusCtrl"] ":")
        this.gui.add("Edit", "w320 r4 ReadOnly -Wrap vCtrl")
        this.gui.add("Text",, "Active Window Position:")
        this.gui.add("Edit", "w320 r2 ReadOnly -Wrap vPos")
        this.gui.add("Text",, "Status Bar Text:")
        this.gui.add("Edit", "w320 r2 ReadOnly -Wrap vSBText")
        this.gui.add("Checkbox", "vIsSlow", "Slow TitleMatchMode")
        this.gui.add("Text",, "Visible Text:")
        this.gui.add("Edit", "w320 r2 ReadOnly -Wrap vVisText")
        this.gui.add("Text",, "All Text:")
        this.gui.add("Edit", "w320 r2 ReadOnly -Wrap vAllText")

        this.gui.add("GroupBox", "w320 r3 vOptions", "Options")
        this.gui.add("Checkbox", "xm+8 yp+16 vAlwaysOnTop checked", "Always on top")
            .OnEvent("Click", ObjBindMethod(this, "OnOptionAlwaysOnTopChanged"))
        this.gui.add("Text", "xm+8 y+m", "Update when Ctrl key is")
        this.gui.add("Radio", "yp vUpdateWhenCtrlUp checked", "up")
            .OnEvent("Click", ObjBindMethod(this, "OnOptionUpdateChange"))
        this.gui.add("Radio", "yp vUpdateWhenCtrlDown", "down")
            .OnEvent("Click", ObjBindMethod(this, "OnOptionUpdateChange"))
        this.gui.add("Text", "xm+8 y+m", "Get info of")
        this.gui.add("Radio", "yp vGetActive checked", "Active window")
            .OnEvent("Click", ObjBindMethod(this, "OnOptionTargetChange"))
        this.gui.add("Radio", "yp vGetCursor", "Window on cursor")
            .OnEvent("Click", ObjBindMethod(this, "OnOptionTargetChange"))
        ; Update label once
        this.OnOptionTargetChange()

        this.statusBar := this.gui.add("StatusBar",, this.textList["NotFrozen"])

        this.gui.OnEvent("size", ObjBindMethod(this, "OnResize"))
        this.gui.OnEvent("close", ObjBindMethod(this, "OnClose"))

        this.OnUpdate := ObjBindMethod(this, "Update")
    }

    SetText(controlID, text) {
        ; Unlike using a pure GuiControl, this function causes the text of the
        ; controls to be updated only when the text has changed, preventing periodic
        ; flickering (especially on older systems).
        if (!this.textCache.has(controlID) || this.textCache[controlID] != text) {
            this.textCache[controlID] := text
            this.gui[controlID].value := text
        }
    }

    UpdateTarget() {
        if this.gui["GetCursor"].value {
            MouseGetPos(,, &window, &control, 2)
            this.window := window
            this.control := control
        } else {
            this.window := WinExist("A")
            try {
                this.control := ControlGetFocus()
            } catch TargetError {
                this.control := 0
            }
        }
    }

    Update() {
        this.UpdateTarget()

        ; Our Gui || Alt-tab
        try {
            if (this.window = this.gui.Hwnd || WinGetClass() = "MultitaskingViewFrame") {
                this.statusBar.SetText(this.textList["Frozen"])
                return
            }
        } catch TargetError {

        }

        if (this.window && this.control) {
            this.SetText("Ctrl", GetControlInfo(this.window, this.control))
        } else {
            this.SetText("Ctrl", "")
        }

        this.statusBar.SetText(this.textList["NotFrozen"])

        this.SetText("Title", GetWindowInfo(this.window))
        this.SetText("MousePos", GetMouseInfo())
        this.SetText("Pos", GetWindowPosInfo(this.window))
        this.SetText("SBText", GetStatusBarText(this.window))
        this.SetText("VisText", GetVisibleText(this.window, this.gui["IsSlow"].Value))
        this.SetText("AllText", GetAllText(this.window, this.gui["IsSlow"].Value))
    }

    autoUpdate(enable) {
        if (enable == this.autoUpdateEnabled) {
            return
        }
        if (enable) {
            SetTimer(this.OnUpdate, 100)
        } else {
            SetTimer(this.OnUpdate, 0)
            this.statusBar.SetText(this.textList["Frozen"])
        }
        this.autoUpdateEnabled := enable
    }
    
    updateAutoUpdateTimer() {
        local ctrlKeyDown := GetKeyState("Ctrl", "P")
        local enable := (
            ctrlKeyDown == window.gui["UpdateWhenCtrlDown"].value
        )
        this.autoUpdate(enable)
    }

}

global window := MainWindow()
window.gui.Show("NoActivate")
window.autoUpdate(true)

~*Ctrl::
~*Ctrl up:: {
    global window
    window.updateAutoUpdateTimer()
}
