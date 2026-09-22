# ============================================================
#  IMR PART SEARCH   -   OCR APPROACH
# ============================================================
#  A small always-on-top search box. The operator types a part
#  number, and the tool screenshots the IMR grid, reads it with
#  the BUILT-IN Windows OCR engine, finds the matching row, and
#  draws a bright highlight overlay on that row so the operator
#  knows exactly which line to click.
#
#  If the part is not on the current screen, the tool scrolls
#  the grid one page at a time, re-screenshots, and re-OCRs,
#  repeating until it finds the part or reaches the bottom.
#
#  STOCK WINDOWS ONLY. Nothing installed, nothing downloaded.
#  Uses only System.Drawing, System.Windows.Forms, and the
#  Windows.Media.Ocr engine that ships with Windows 10/11.
#  The only thing placed on the machine is this script file.
#
#  WHAT THIS DOES NOT DO:
#    - does not install anything
#    - does not modify IMR or its memory
#    - does not write to any database
#    - does not click anything in IMR (by default)
#  It reads pixels, moves the mouse wheel, and draws an overlay.
#
#  HOW TO RUN: open Windows PowerShell, open this file in
#  Notepad, Ctrl+A, Ctrl+C, right click inside the PowerShell
#  window and press Enter.
# ============================================================

# ==================== CONFIG ====================
# A word from IMR's title bar
$WindowMatch  = 'Incoming'
# How much to upscale the capture before OCR. 2-3 helps small text.
$Upscale      = 2.0
# Boost contrast to help separate text from grid lines. 1 = off.
$Contrast     = 1.0
# Milliseconds to wait after scrolling before re-capturing.
$ScrollDelay  = 200
# Maximum pages to scroll before giving up.
$MaxPages     = 200
# Seconds the highlight overlay stays visible.
$HighlightSec = 8
# Fuzzy match: treat common OCR confusable characters as equivalent.
$FuzzyOCR     = $true
# ================================================

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Language CSharp @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class Win {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public static List<IntPtr> Tops() {
        List<IntPtr> l = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr p) { if (IsWindowVisible(h)) l.Add(h); return true; }, IntPtr.Zero);
        return l;
    }
    public static List<IntPtr> Kids(IntPtr parent) {
        List<IntPtr> l = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr p) { l.Add(h); return true; }, IntPtr.Zero);
        return l;
    }
    public static string Title(IntPtr h) {
        StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString();
    }
}
"@

# ---- WinRT / Windows.Media.Ocr plumbing ------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($op, $resultType) {
    $asTask  = $asTaskGeneric.MakeGenericMethod($resultType)
    $netTask = $asTask.Invoke($null, @($op))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

$null = [Windows.Media.Ocr.OcrEngine,               Windows.Media.Ocr,           ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,    Windows.Graphics.Imaging,    ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap,   Windows.Graphics.Imaging,    ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataWriter,        Windows.Storage.Streams,     ContentType = WindowsRuntime]

function ConvertTo-SoftwareBitmap([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $bytes = $ms.ToArray()
    $ms.Dispose()

    $ras    = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $writer = New-Object Windows.Storage.Streams.DataWriter($ras)
    $writer.WriteBytes($bytes)
    Await $writer.StoreAsync() ([uint32]) | Out-Null
    $writer.DetachStream() | Out-Null
    $ras.Seek(0)

    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $swBmp   = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    return $swBmp
}

# ---- OCR engine singleton --------------------------------------------
$script:ocrEngine = $null
function Get-OcrEngine {
    if (-not $script:ocrEngine) {
        $script:ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    }
    return $script:ocrEngine
}

# ---- fuzzy matching for OCR confusables ------------------------------
function Normalize-ForOCR([string]$s) {
    if (-not $FuzzyOCR) { return $s.ToUpper() }
    $s.ToUpper().Replace('O','0').Replace('I','1').Replace('L','1').Replace('S','5').Replace('B','8').Replace(' ','')
}

# ---- capture and OCR a window region ---------------------------------
function Capture-And-OCR([int]$left, [int]$top, [int]$w, [int]$h) {
    $shot = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($shot)
    $g.CopyFromScreen($left, $top, 0, 0, $shot.Size)
    $g.Dispose()

    $proc = $shot
    if ($Upscale -ne 1.0 -or $Contrast -ne 1.0) {
        $nw = [int]($w * $Upscale)
        $nh = [int]($h * $Upscale)
        $big = New-Object System.Drawing.Bitmap($nw, $nh)
        $bg  = [System.Drawing.Graphics]::FromImage($big)
        $bg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

        if ($Contrast -ne 1.0) {
            $c = [float]$Contrast
            $t = [float]((1 - $c) / 2)
            $cm = New-Object System.Drawing.Imaging.ColorMatrix
            $cm.Matrix00 = $c; $cm.Matrix11 = $c; $cm.Matrix22 = $c
            $cm.Matrix40 = $t; $cm.Matrix41 = $t; $cm.Matrix42 = $t
            $ia = New-Object System.Drawing.Imaging.ImageAttributes
            $ia.SetColorMatrix($cm)
            $bg.DrawImage($shot, (New-Object System.Drawing.Rectangle(0,0,$nw,$nh)), 0,0,$w,$h, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        } else {
            $bg.DrawImage($shot, 0, 0, $nw, $nh)
        }
        $bg.Dispose()
        $proc = $big
    }

    $eng = Get-OcrEngine
    if (-not $eng) { return $null }

    $swBmp  = ConvertTo-SoftwareBitmap $proc
    $result = Await ($eng.RecognizeAsync($swBmp)) ([Windows.Media.Ocr.OcrResult])

    $shot.Dispose()
    if ($proc -ne $shot) { $proc.Dispose() }

    return $result
}

# ---- find IMR window -------------------------------------------------
function Find-TargetWindow {
    foreach ($h in [Win]::Tops()) {
        $ti = [Win]::Title($h)
        if ($ti -and $ti -match $WindowMatch) { return $h }
    }
    return [IntPtr]::Zero
}

# ---- group OCR lines into grid rows by Y clustering -----------------
# OCR gives us lines, but one grid row might span multiple OCR lines.
# We group by Y coordinate with a tolerance to cluster them into rows.
function Group-IntoRows($ocrResult, [float]$scale) {
    $items = @()
    foreach ($line in $ocrResult.Lines) {
        $lineText = ($line.Words | ForEach-Object { $_.Text }) -join ' '
        $yCenter  = ($line.Words[0].BoundingRect.Y + $line.Words[0].BoundingRect.Height / 2) / $scale
        $yTop     = $line.Words[0].BoundingRect.Y / $scale
        $yBot     = ($line.Words[0].BoundingRect.Y + $line.Words[0].BoundingRect.Height) / $scale
        $xLeft    = $line.Words[0].BoundingRect.X / $scale
        $xRight   = ($line.Words[-1].BoundingRect.X + $line.Words[-1].BoundingRect.Width) / $scale

        $items += [pscustomobject]@{
            Text    = $lineText
            YCenter = $yCenter
            YTop    = $yTop
            YBot    = $yBot
            XLeft   = $xLeft
            XRight  = $xRight
        }
    }

    if ($items.Count -eq 0) { return @() }

    $items = $items | Sort-Object YCenter
    $rowTolerance = 8
    $rows = @()
    $curRow = @($items[0])
    for ($i = 1; $i -lt $items.Count; $i++) {
        if ([Math]::Abs($items[$i].YCenter - $curRow[-1].YCenter) -le $rowTolerance) {
            $curRow += $items[$i]
        } else {
            $rows += ,@($curRow)
            $curRow = @($items[$i])
        }
    }
    $rows += ,@($curRow)
    return $rows
}

# ---- search one captured screen for the part number ------------------
function Search-Screen($ocrResult, [string]$term, [float]$scale) {
    $normTerm = Normalize-ForOCR $term
    $rows = Group-IntoRows $ocrResult $scale
    foreach ($row in $rows) {
        $rowParts = $row | Sort-Object XLeft
        $fullText = ($rowParts | ForEach-Object { $_.Text }) -join ' '
        $normRow  = Normalize-ForOCR $fullText
        if ($normRow.Contains($normTerm)) {
            $yTop  = ($rowParts | Measure-Object -Property YTop -Minimum).Minimum
            $yBot  = ($rowParts | Measure-Object -Property YBot -Maximum).Maximum
            $xLeft = ($rowParts | Measure-Object -Property XLeft -Minimum).Minimum
            $xRight= ($rowParts | Measure-Object -Property XRight -Maximum).Maximum
            return [pscustomobject]@{
                FullText = $fullText
                YTop     = [int]$yTop
                YBot     = [int]$yBot
                XLeft    = [int]$xLeft
                XRight   = [int]$xRight
            }
        }
    }
    return $null
}

# ---- highlight overlay -----------------------------------------------
# A borderless, always-on-top, click-through transparent form that
# draws a bright box over the found row. Dismisses on timer or keypress.
function Show-Highlight([int]$screenX, [int]$screenY, [int]$w, [int]$h, [int]$durationMs) {
    $pad = 4
    $ov = New-Object System.Windows.Forms.Form
    $ov.FormBorderStyle = 'None'
    $ov.TopMost         = $true
    $ov.ShowInTaskbar   = $false
    $ov.StartPosition   = 'Manual'
    $ov.Location        = New-Object System.Drawing.Point(([Math]::Max(0, $screenX - $pad)), ([Math]::Max(0, $screenY - $pad)))
    $ov.Size            = New-Object System.Drawing.Size(($w + 2*$pad), ($h + 2*$pad))
    $ov.BackColor       = [System.Drawing.Color]::Yellow
    $ov.Opacity         = 0.35
    $ov.Cursor          = [System.Windows.Forms.Cursors]::Hand

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = $durationMs
    $timer.Add_Tick({ $ov.Close() })
    $timer.Start()

    $ov.Add_Click({ $ov.Close() })
    $ov.Add_KeyPress({ $ov.Close() })
    $ov.Add_FormClosing({ $timer.Stop(); $timer.Dispose() })

    $ov.Show()
    return $ov
}

# ---- scroll the grid -------------------------------------------------
function Scroll-GridDown([IntPtr]$hwnd) {
    $WM_MOUSEWHEEL = 0x020A
    $WHEEL_DELTA   = -120 * 3
    $packed = [IntPtr]([int64]($WHEEL_DELTA -shl 16))

    $clientRect = New-Object Win+RECT
    [Win]::GetClientRect($hwnd, [ref]$clientRect) | Out-Null
    $pt = New-Object Win+POINT
    $pt.X = [int](($clientRect.Right - $clientRect.Left) / 2)
    $pt.Y = [int](($clientRect.Bottom - $clientRect.Top) / 2)
    [Win]::ClientToScreen($hwnd, [ref]$pt) | Out-Null
    $lparam = [IntPtr]([int64](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF)))

    [Win]::PostMessage($hwnd, $WM_MOUSEWHEEL, $packed, $lparam) | Out-Null
}

function Scroll-GridToTop([IntPtr]$hwnd) {
    $WM_VSCROLL = 0x0115
    $SB_TOP     = [IntPtr]6
    [Win]::SendMessage($hwnd, $WM_VSCROLL, $SB_TOP, [IntPtr]::Zero) | Out-Null
}

# ---- the main search pipeline ----------------------------------------
$script:targetHwnd  = [IntPtr]::Zero
$script:overlayForm = $null
$script:lastHash    = ''

function Do-Search([string]$term, [System.Windows.Forms.Label]$statusLbl, [System.Windows.Forms.Form]$parentForm) {
    if ($script:overlayForm -and -not $script:overlayForm.IsDisposed) {
        $script:overlayForm.Close()
    }

    if (-not $term) { return }

    $hwnd = Find-TargetWindow
    if ($hwnd -eq [IntPtr]::Zero) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "IMR window not found. Is it open?"
        return
    }
    $script:targetHwnd = $hwnd

    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    $ww = $rect.Right - $rect.Left
    $wh = $rect.Bottom - $rect.Top
    if ($ww -le 0 -or $wh -le 0) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "IMR window has no usable size."
        return
    }

    $winLeft = $rect.Left
    $winTop  = $rect.Top

    $statusLbl.ForeColor = [System.Drawing.Color]::Black
    $statusLbl.Text = "Scanning current view..."
    $parentForm.Refresh()

    $scale = if ($Upscale -ne 1.0) { $Upscale } else { 1.0 }
    $ocrResult = Capture-And-OCR $winLeft $winTop $ww $wh
    if (-not $ocrResult) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "Windows OCR is not available on this PC."
        return
    }

    $hit = Search-Screen $ocrResult $term $scale
    if ($hit) {
        $sx = $winLeft + $hit.XLeft
        $sy = $winTop  + $hit.YTop
        $sw = $hit.XRight - $hit.XLeft
        $sh = $hit.YBot   - $hit.YTop

        $script:overlayForm = Show-Highlight $sx $sy $sw $sh ($HighlightSec * 1000)

        $statusLbl.ForeColor = [System.Drawing.Color]::ForestGreen
        $statusLbl.Text = "Found: $($hit.FullText)"
        $parentForm.TopMost = $true
        return
    }

    # not on this screen, start scrolling
    $statusLbl.ForeColor = [System.Drawing.Color]::Black
    $statusLbl.Text = "Not on screen. Scrolling to top..."
    $parentForm.Refresh()

    [Win]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 80
    Scroll-GridToTop $hwnd
    Start-Sleep -Milliseconds $ScrollDelay

    $prevText = ''
    for ($page = 0; $page -lt $MaxPages; $page++) {
        [Win]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        $winLeft = $rect.Left
        $winTop  = $rect.Top
        $ww = $rect.Right - $rect.Left
        $wh = $rect.Bottom - $rect.Top

        $statusLbl.Text = "Scanning page $($page + 1)..."
        $parentForm.Refresh()

        $ocrResult = Capture-And-OCR $winLeft $winTop $ww $wh
        if (-not $ocrResult) { break }

        $currentText = $ocrResult.Text
        if ($currentText -eq $prevText -and $page -gt 0) {
            $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
            $statusLbl.Text = "Not found after scrolling the whole grid ($($page + 1) pages)."
            $parentForm.TopMost = $true
            return
        }
        $prevText = $currentText

        $hit = Search-Screen $ocrResult $term $scale
        if ($hit) {
            $sx = $winLeft + $hit.XLeft
            $sy = $winTop  + $hit.YTop
            $sw = $hit.XRight - $hit.XLeft
            $sh = $hit.YBot   - $hit.YTop

            $script:overlayForm = Show-Highlight $sx $sy $sw $sh ($HighlightSec * 1000)

            $statusLbl.ForeColor = [System.Drawing.Color]::ForestGreen
            $statusLbl.Text = "Found on page $($page + 1): $($hit.FullText)"
            $parentForm.TopMost = $true
            return
        }

        Scroll-GridDown $hwnd
        Start-Sleep -Milliseconds $ScrollDelay
    }

    $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
    $statusLbl.Text = "Not found after $MaxPages pages."
    $parentForm.TopMost = $true
}

# ---- UI --------------------------------------------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "Find Part  (OCR)   Ctrl+Shift+F to recall"
$form.Size            = New-Object System.Drawing.Size(430, 180)
$form.TopMost         = $true
$form.FormBorderStyle = 'FixedSingle'
$form.MinimizeBox     = $true
$form.MaximizeBox     = $false
$form.ShowInTaskbar   = $true
$form.StartPosition   = 'Manual'
$form.Location        = New-Object System.Drawing.Point(30, 30)
$form.BackColor       = [System.Drawing.Color]::White

$txt          = New-Object System.Windows.Forms.TextBox
$txt.Location = New-Object System.Drawing.Point(12, 14)
$txt.Size     = New-Object System.Drawing.Size(285, 32)
$txt.Font     = New-Object System.Drawing.Font("Segoe UI", 14)
$form.Controls.Add($txt)

$btnSearch          = New-Object System.Windows.Forms.Button
$btnSearch.Text     = "Search"
$btnSearch.Location = New-Object System.Drawing.Point(306, 13)
$btnSearch.Size     = New-Object System.Drawing.Size(75, 33)
$form.Controls.Add($btnSearch)

$btnSlim          = New-Object System.Windows.Forms.Button
$btnSlim.Text     = "Shrink"
$btnSlim.Location = New-Object System.Drawing.Point(12, 54)
$btnSlim.Size     = New-Object System.Drawing.Size(65, 26)
$btnSlim.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($btnSlim)

$hint          = New-Object System.Windows.Forms.Label
$hint.Text     = "Type a part number and press Enter"
$hint.Location = New-Object System.Drawing.Point(86, 58)
$hint.Size     = New-Object System.Drawing.Size(300, 20)
$hint.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$hint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($hint)

$lbl          = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point(12, 88)
$lbl.Size     = New-Object System.Drawing.Size(400, 52)
$lbl.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($lbl)

function Say([string]$m, $c) { $lbl.ForeColor = $c; $lbl.Text = $m; $form.Refresh() }

$doFind = {
    $term = $txt.Text.Trim()
    if (-not $term) { return }
    Do-Search $term $lbl $form
    $txt.SelectAll()
    $txt.Focus()
}

$txt.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $doFind } })
$btnSearch.Add_Click({ & $doFind })

# ---- shrink / expand -------------------------------------------------
$script:slim = $false
$btnSlim.Add_Click({
    if ($script:slim) {
        $form.Size = New-Object System.Drawing.Size(430, 180)
        $btnSlim.Text = "Shrink"
        $script:slim = $false
    } else {
        $form.Size = New-Object System.Drawing.Size(430, 72)
        $btnSlim.Text = "Expand"
        $script:slim = $true
    }
})

# ---- global recall hotkey: Ctrl + Shift + F --------------------------
$script:hotHeld = $false
$hotTimer          = New-Object System.Windows.Forms.Timer
$hotTimer.Interval = 150
$hotTimer.Add_Tick({
    $ctrl  = ([Win]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $shift = ([Win]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
    $f     = ([Win]::GetAsyncKeyState(0x46) -band 0x8000) -ne 0
    if ($ctrl -and $shift -and $f) {
        if (-not $script:hotHeld) {
            $script:hotHeld = $true
            if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
            $form.TopMost = $true
            $form.Activate()
            $txt.Focus()
            $txt.SelectAll()
        }
    } else {
        $script:hotHeld = $false
    }
})
$hotTimer.Start()

$form.Add_FormClosing({
    $hotTimer.Stop()
    if ($script:overlayForm -and -not $script:overlayForm.IsDisposed) {
        $script:overlayForm.Close()
    }
})

$form.Add_Shown({
    $txt.Focus()
    $eng = Get-OcrEngine
    if ($eng) {
        Say "Ready. OCR engine loaded." ([System.Drawing.Color]::ForestGreen)
    } else {
        Say "Windows OCR is not available on this PC.`nSettings > Apps > Optional features > English OCR." ([System.Drawing.Color]::Firebrick)
    }
})

Write-Host ""
Write-Host "Find Part (OCR) is running. Close its window to stop." -ForegroundColor Green
Write-Host ""

[System.Windows.Forms.Application]::Run($form)
