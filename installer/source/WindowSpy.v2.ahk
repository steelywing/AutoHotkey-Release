;
; Window Spy
;

; #NoTrayIcon
#SingleInstance Ignore
SetWorkingDir A_ScriptDir
; SetBatchLines -1
CoordMode "Pixel", "Screen"
; Ignore error, sometimes WinExist() will issue window not found error
; Comment this out when debug
; OnError((*) => true)

WinGetTextFast(detect_hidden) {
    ; WinGetText ALWAYS uses the "fast" mode - TitleMatchMode only affects
    ; WinText/ExcludeText parameters.  In Slow mode, GetWindowText() is used
    ; to retrieve the text of each control.
    try {
        controls := WinGetControlsHwnd()
    } catch TargetError {
        return ""
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
        WinGetPos(&wX, &wY,,, "ahk_id " hWnd)
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

class MainWindow {
    updateClosure := ""
    textCache := Map()
    autoUpdateEnabled := false

    textList := Map(
        "NotFrozen", "Updating...",
        "Frozen", "Update suspended",
        "MouseCtrl", "Control Under Mouse Position",
        "FocusCtrl", "Focused Control",
    )

    onOptionUpdateChange(*) {
        this.updateAutoUpdateTimer()
    }

    onOptionAlwaysOnTopChanged(checkbox, *) {
        this.gui.opt(
            (checkbox.value ? "+" : "-")
            "AlwaysOnTop"
        )
    }

    OnResize(window, minMax, width, height) {
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
            .OnEvent("Click", ObjBindMethod(this, "onOptionAlwaysOnTopChanged"))
        this.gui.add("Text", "xm+8 y+m", "Update when Ctrl key is")
        this.gui.add("Radio", "yp vUpdateWhenCtrlUp checked", "up")
            .OnEvent("Click", ObjBindMethod(this, "onOptionUpdateChange"))
        this.gui.add("Radio", "yp vUpdateWhenCtrlDown", "down")
            .OnEvent("Click", ObjBindMethod(this, "onOptionUpdateChange"))
        this.gui.add("Text", "xm+8 y+m", "Get info of")
        this.gui.add("Radio", "yp vGetActive checked", "Active window")
        this.gui.add("Radio", "yp vGetCursor", "Window on cursor")

        this.statusBar := this.gui.add("StatusBar",, this.textList["NotFrozen"])

        this.gui.OnEvent("size", ObjBindMethod(this, "OnResize"))
        this.gui.OnEvent("close", ObjBindMethod(this, "OnClose"))

        ; Create updateClosure for timer
        this.updateClosure := () => this.update()
    }

    setText(controlID, text) {
        ; Unlike using a pure GuiControl, this function causes the text of the
        ; controls to be updated only when the text has changed, preventing periodic
        ; flickering (especially on older systems).
        if (!this.textCache.has(controlID) || this.textCache[controlID] != text) {
            this.textCache[controlID] := text
            this.gui[controlID].value := text
        }
    }

    update() {
        local curCtrl
        CoordMode("Mouse", "Screen")
        MouseGetPos(&msX, &msY, &msWin, &msCtrl)
        if this.gui["GetCursor"].value {
            curWin := msWin
            curCtrl := msCtrl
            WinExist("ahk_id " curWin)
        } else {
            curWin := WinExist("A")
            if (!curWin) {
                return
            }
            try {
                curCtrl := ControlGetFocus()
            } catch TargetError {
                curCtrl := false
            }
        }

        ; Our Gui || Alt-tab
        try {
            if (curWin = this.gui.Hwnd || WinGetClass() = "MultitaskingViewFrame") {
                this.statusBar.setText(this.textList["Frozen"])
                return
            }
        } catch TargetError {

        }

        this.statusBar.setText(this.textList["NotFrozen"])
        try {
            this.setText(
                "Title", 
                WinGetTitle() 
                "`nahk_class " WinGetClass() 
                "`nahk_exe " WinGetProcessName() 
                "`nahk_pid " WinGetPID()
            )
        } catch TargetError as e {
            this.setText("Title", "Get window info fail: " e)
        }
        CoordMode "Mouse", "Window"
        MouseGetPos &mrX, &mrY
        CoordMode "Mouse", "Client"
        MouseGetPos &mcX, &mcY
        mClr := PixelGetColor(msX, msY)
        mClr := SubStr(mClr, 3)
        this.setText(
            "MousePos", 
            "Screen:`t" msX ", " msY "`n"
            "Window:`t" mrX ", " mrY "`n"
            "Client:`t" mcX ", " mcY "`n"
            "Color:`t#" mClr
        )
        this.setText(
            "CtrlLabel", 
            (this.gui["GetCursor"].value ? this.textList["MouseCtrl"] : this.textList["FocusCtrl"]) ":"
        )
        cText := ""
        if (curCtrl) {
            try {
                cText := "Class:`t" WinGetClass(curCtrl) "`n"
                cText .= "Text:`t" textMangle(ControlGetText(curCtrl)) "`n"
                ControlGetPos &cX, &cY, &cW, &cH, curCtrl
                cText .= "`tX: " cX "`tY: " cY "`tW: " cW "`tH: " cH
                ScreenToClientPos(curWin, &cX, &cY)
                curCtrlHwnd := ControlGetHwnd(curCtrl)
                WinGetClientPos(,, &cW, &cH, curCtrlHwnd)
                cText .= "`nClient:`tX: " cX "`tY: " cY "`tW: " cW "`tH: " cH
                this.setText("Ctrl", cText)
            } catch TargetError as e {
                this.setText("Get control info fail: " e)
            }
        }
        try {
            WinGetPos(&wX, &wY, &wW, &wH)
            WinGetClientPos(&wcX, &wcY, &wcW, &wcH, curWin)
            this.setText(
                "Pos", 
                "`tX: " wX 
                "`tY: " wY 
                "`tW: " wW 
                "`tH: " wH 
                "`nClient:`tX: " wcX "`tY: " wcY "`tW: " wcW "`tH: " wcH
            )
        } catch TargetError as e {
            this.setText("Get window position fail" e)
        }
        sbTxt := ""
        loop {
            try {
                sbTxt .= "[" A_Index "]`t" textMangle(StatusBarGetText(A_Index)) "`n"
            } catch as e {
                break
            }
        }
        sbTxt := SubStr(sbTxt, 1, -1)
        this.setText("SBText", sbTxt)
        if this.gui["IsSlow"].Value {
            DetectHiddenText(False)
            ovVisText := WinGetText()
            DetectHiddenText(True)
            ovAllText := WinGetText()
        } else {
            ovVisText := WinGetTextFast(false)
            ovAllText := WinGetTextFast(true)
        }
        this.setText("VisText", ovVisText)
        this.setText("AllText", ovAllText)
    }

    autoUpdate(enable) {
        if (enable == this.autoUpdateEnabled) {
            return
        }
        if (enable) {
            SetTimer(this.updateClosure, 100)
        } else {
            SetTimer(this.updateClosure, 0)
            this.statusBar.setText(this.textList["Frozen"])
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
