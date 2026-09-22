# ============================================================
#  IMR PART SEARCH   -   OCR APPROACH
# ============================================================
#  A small always-on-top search box. The operator types a part
#  number, and the tool screenshots the IMR grid, reads it with
#  the BUILT-IN Windows OCR engine, finds the matching row, then
#  moves the mouse onto that row and clicks it, so IMR selects
#  the row exactly as if the operator had clicked it themselves.
#
#  If the part is not on the current screen, the tool scrolls by
#  spinning the real mouse wheel over the grid, re-screenshots and
#  re-OCRs after each step, and sweeps DOWN to the bottom then
#  back UP to the top. Those two passes cover the whole grid from
#  wherever the operator happened to be sitting, which matters
#  because there is no dependable way to jump to a known row.
#  Press Esc to abort a long search.
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
#  It reads pixels, moves the mouse, and issues ONE left click on
#  the matched row. That click is the same input a human hand
#  would produce. It never types, never presses a button, and
#  refuses to click at all if the target falls outside the grid
#  window. Set $AutoClick = $false to only park the pointer on
#  the row and leave the clicking to the operator.
#
#  HOW TO RUN: double-click IMR-Part-Search.bat. That is the
#  only file you need to open. Pick the window to search from
#  the dropdown at the top (or leave it on auto), type a part
#  number, press Enter. The "Test grid" button opens a sample
#  grid so you can try it without IMR.
# ============================================================

# ==================== CONFIG ====================
# A word from IMR's title bar
$WindowMatch  = 'Incoming'
# How much to upscale the capture before OCR. 2-3 helps small text.
$Upscale      = 2.0
# Boost contrast to help separate text from grid lines. 1 = off.
$Contrast     = 1.0
# Milliseconds to wait after scrolling before re-capturing.
$ScrollDelay  = 220
# Wheel notches per scroll step. Most grids move 3 rows per notch, so 5
# advances about 15 rows. Lower this if rows are being skipped between
# scans; raise it to search long orders faster.
$WheelNotches = 5
# Maximum scroll steps before giving up.
$MaxPages     = 200
# Fuzzy match: treat common OCR confusable characters as equivalent.
$FuzzyOCR     = $true
# Click the matched row automatically. Set to $false to only move the
# mouse pointer there and let the operator click, which is the safer
# setting while you are still confirming the tool aims correctly.
$AutoClick    = $true
# How far right of the row's leftmost text to click, in pixels. This
# should land inside the Part Number cell, not on the row edge.
$ClickInsetX  = 25
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
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    // dwData is declared int, not uint, so a negative wheel delta
    // (scroll down) can be passed straight through.
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, IntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

    // The top-level window that owns whatever is drawn at this screen
    // point, or zero if nothing is there.
    public static IntPtr RootAt(int x, int y) {
        POINT p; p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return IntPtr.Zero;
        return GetAncestor(h, 2); // GA_ROOT
    }
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

# Opt into real screen pixels before any window exists. Without this,
# Windows virtualises coordinates for this process on a scaled display
# (125%, 150%), so the pixel the screenshot was taken from and the pixel
# the mouse is sent to are different points and the click lands on the
# wrong row. Everything downstream now shares one coordinate space.
try { [Win]::SetProcessDPIAware() | Out-Null } catch { }

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
    # Do-Search drops our own window behind the grid before calling this,
    # so the search box (which holds the very term being looked for, and
    # would otherwise be read back as a false match) is not in the pixels.
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

# ---- window picking --------------------------------------------------
# The operator picks the target window from a dropdown. Until they pick
# one, we fall back to matching the title against $WindowMatch so the
# tool still works out of the box on a normal IMR desktop.
$script:pickedHwnd = [IntPtr]::Zero

function Get-PickableWindows {
    $list = @()
    foreach ($h in [Win]::Tops()) {
        $ti = [Win]::Title($h)
        if (-not $ti) { continue }
        if ($ti -eq $script:selfTitle) { continue }

        $r = New-Object Win+RECT
        [Win]::GetWindowRect($h, [ref]$r) | Out-Null
        if (($r.Right - $r.Left) -lt 120 -or ($r.Bottom - $r.Top) -lt 80) { continue }

        $list += [pscustomobject]@{
            Hwnd  = $h
            Title = $ti
        }
    }
    return $list
}

function Find-TargetWindow {
    if ($script:pickedHwnd -ne [IntPtr]::Zero -and [Win]::IsWindow($script:pickedHwnd)) {
        return $script:pickedHwnd
    }
    foreach ($h in [Win]::Tops()) {
        $ti = [Win]::Title($h)
        if ($ti -and $ti -eq $script:selfTitle) { continue }
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
        $words = @($line.Words)
        if ($words.Count -eq 0) { continue }
        $lineText = ($words | ForEach-Object { $_.Text }) -join ' '

        $minX = [double]::MaxValue
        $maxX = 0.0
        $minY = [double]::MaxValue
        $maxY = 0.0
        foreach ($w in $words) {
            $br = $w.BoundingRect
            $wx = [double]$br.X
            $wy = [double]$br.Y
            $ww = [double]$br.Width
            $wh = [double]$br.Height
            if ($wx -lt $minX) { $minX = $wx }
            if (($wx + $ww) -gt $maxX) { $maxX = $wx + $ww }
            if ($wy -lt $minY) { $minY = $wy }
            if (($wy + $wh) -gt $maxY) { $maxY = $wy + $wh }
        }

        $items += [pscustomobject]@{
            Text    = $lineText
            YCenter = (($minY + $maxY) / 2) / $scale
            YTop    = $minY / $scale
            YBot    = $maxY / $scale
            XLeft   = $minX / $scale
            XRight  = $maxX / $scale
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

# ---- go to the matched row -------------------------------------------
# Moves the pointer onto the row and clicks it, so IMR selects the row
# exactly as if the operator had clicked it themselves.
#
# A stray click in IMR could hit Print Labels or Clear, so the target is
# rejected unless it lies inside the captured window AND that window is
# what is actually drawn there AND the pointer reached it. Failing any
# of those we do nothing and say so, rather than click blind.
function Invoke-RowClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [System.Windows.Forms.Label]$statusLbl) {
    $r = New-Object Win+RECT
    [Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null

    if ($screenX -lt $r.Left -or $screenX -gt $r.Right -or
        $screenY -lt $r.Top  -or $screenY -gt $r.Bottom) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "Row found but its position looks wrong. Not clicking."
        return $false
    }

    # The grid must be what is actually drawn at that point, so a window
    # sitting over it cannot swallow the click.
    if ([Win]::RootAt($screenX, $screenY) -ne $hwnd) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "Something is covering that row. Not clicking."
        return $false
    }

    [Win]::SetCursorPos($screenX, $screenY) | Out-Null
    Start-Sleep -Milliseconds 90

    if (-not $AutoClick) { return $true }

    # Confirm the pointer landed where we asked before clicking.
    $now = New-Object Win+POINT
    [Win]::GetCursorPos([ref]$now) | Out-Null
    if ([Math]::Abs($now.X - $screenX) -gt 3 -or [Math]::Abs($now.Y - $screenY) -gt 3) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "Could not position the pointer. Not clicking."
        return $false
    }

    $MOUSEEVENTF_LEFTDOWN = 0x0002
    $MOUSEEVENTF_LEFTUP   = 0x0004
    [Win]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [Win]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    return $true
}

# ---- scroll the grid -------------------------------------------------
# The rows live in a child control inside the window, so posting
# WM_MOUSEWHEEL or WM_VSCROLL to the top-level handle scrolls nothing --
# the messages never reach the control that owns the scrollbar, and we
# have no reliable way to identify that control in an owner-drawn grid.
#
# Instead we park the real mouse pointer over the grid and emit a real
# wheel event. Windows then routes it to whatever is under the pointer,
# exactly as if the operator had spun the wheel, so it works regardless
# of how the grid is built.
function Get-GridPoint([IntPtr]$hwnd) {
    $r = New-Object Win+RECT
    [Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    # 60% down the window, to stay clear of the toolbar and headers.
    $x = $r.Left + [int](($r.Right  - $r.Left) * 0.5)
    $y = $r.Top  + [int](($r.Bottom - $r.Top)  * 0.6)
    return ,@($x, $y)
}

# $notches is positive to scroll up, negative to scroll down.
function Send-Wheel([IntPtr]$hwnd, [int]$notches) {
    $MOUSEEVENTF_WHEEL = 0x0800
    $p = Get-GridPoint $hwnd

    # If the grid is not what sits under that point, a wheel event there
    # would scroll some other window instead. Say nothing and do nothing.
    if ([Win]::RootAt($p[0], $p[1]) -ne $hwnd) { return $false }

    [Win]::SetCursorPos($p[0], $p[1]) | Out-Null
    Start-Sleep -Milliseconds 20
    [Win]::mouse_event($MOUSEEVENTF_WHEEL, 0, 0, ($notches * 120), [IntPtr]::Zero)
    return $true
}

# ---- the main search pipeline ----------------------------------------
# Capture the target window and look for the term. Returns the hit, or
# $null, plus the raw page text so the caller can tell when scrolling has
# stopped moving.
function Scan-Once([IntPtr]$hwnd, [string]$term, [float]$scale) {
    $r = New-Object Win+RECT
    [Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { return $null }

    $ocr = Capture-And-OCR $r.Left $r.Top $w $h
    if (-not $ocr) { return $null }

    return [pscustomobject]@{
        Hit     = (Search-Screen $ocr $term $scale)
        Text    = $ocr.Text
        WinLeft = $r.Left
        WinTop  = $r.Top
    }
}

function Do-Search([string]$term, [System.Windows.Forms.Label]$statusLbl, [System.Windows.Forms.Form]$parentForm) {
    if (-not $term) { return }

    $hwnd = Find-TargetWindow
    if ($hwnd -eq [IntPtr]::Zero) {
        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "No target window. Pick one from the dropdown."
        return
    }

    # Step out of always-on-top and put the grid in front for the whole
    # search. This is what makes the rest work: our own box is no longer
    # in the captured pixels, no longer under the pointer when the wheel
    # is spun, and no longer able to swallow the click.
    $wasTop = $parentForm.TopMost
    $parentForm.TopMost = $false

    try {
        $SW_RESTORE = 9
        if ([Win]::IsIconic($hwnd)) {
            [Win]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
            Start-Sleep -Milliseconds 250
        }
        [Win]::SetForegroundWindow($hwnd) | Out-Null
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150

        $scale = if ($Upscale -ne 1.0) { $Upscale } else { 1.0 }

        $scan = Scan-Once $hwnd $term $scale
        if (-not $scan) {
            $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
            $statusLbl.Text = "Could not read the window. Is Windows OCR available?"
            return
        }
        if ($scan.Hit) {
            Report-Hit $hwnd $scan 0 $statusLbl
            return
        }

        # The row is off-screen. Sweep down to the bottom, then back up
        # past the starting point to the top. Between them those two
        # passes cover the whole grid without ever needing to jump to a
        # known position, which no message we can send would do reliably.
        $prevText = $scan.Text
        $total    = 0

        foreach ($dir in @(-1, 1)) {
            $label = if ($dir -lt 0) { "down" } else { "up" }

            # $MaxPages bounds each pass separately. A long sweep down
            # must not leave the sweep back up unable to reach the top.
            for ($step = 0; $step -lt $MaxPages; $step++) {
                # A long sweep holds the mouse and blocks this thread for
                # minutes, so leave the operator a way out.
                if (([Win]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) {
                    $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
                    $statusLbl.Text = "Search cancelled."
                    return
                }

                $statusLbl.ForeColor = [System.Drawing.Color]::Black
                $statusLbl.Text = "Searching $label... ($total)"

                if (-not (Send-Wheel $hwnd ($dir * $WheelNotches))) {
                    $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
                    $statusLbl.Text = "Something is covering the grid. Cannot scroll."
                    return
                }
                Start-Sleep -Milliseconds $ScrollDelay
                $total++

                $scan = Scan-Once $hwnd $term $scale
                if (-not $scan) {
                    $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
                    $statusLbl.Text = "Lost the window while scrolling."
                    return
                }

                if ($scan.Hit) {
                    Report-Hit $hwnd $scan $total $statusLbl
                    return
                }

                # Nothing moved, so this end of the grid is reached.
                if ($scan.Text -eq $prevText) { break }
                $prevText = $scan.Text
            }

            # Force the up pass to run even though the down pass just
            # ended on a page that stopped changing.
            $prevText = ''
        }

        $statusLbl.ForeColor = [System.Drawing.Color]::Firebrick
        $statusLbl.Text = "'$term' not found anywhere in the grid."
    }
    finally {
        if ($wasTop) { $parentForm.TopMost = $true }
    }
}

function Report-Hit([IntPtr]$hwnd, $scan, [int]$pages, [System.Windows.Forms.Label]$statusLbl) {
    $hit = $scan.Hit
    $cx  = $scan.WinLeft + $hit.XLeft + $ClickInsetX
    $cy  = $scan.WinTop  + [int](($hit.YTop + $hit.YBot) / 2)

    if (Invoke-RowClick $hwnd $cx $cy $statusLbl) {
        $statusLbl.ForeColor = [System.Drawing.Color]::ForestGreen
        $verb  = if ($AutoClick) { "Clicked" } else { "Pointer on" }
        $where = if ($pages -gt 0) { " (after $pages scrolls)" } else { "" }
        $statusLbl.Text = "$verb$where`: $($hit.FullText)"
    }
}

# ---- UI --------------------------------------------------------------
$script:selfTitle = "Find Part  (OCR)   Ctrl+Shift+F to recall"

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = $script:selfTitle
$form.Size            = New-Object System.Drawing.Size(430, 232)
$form.TopMost         = $true
$form.FormBorderStyle = 'FixedSingle'
$form.MinimizeBox     = $true
$form.MaximizeBox     = $false
$form.ShowInTaskbar   = $true
$form.StartPosition   = 'Manual'
$form.Location        = New-Object System.Drawing.Point(30, 30)
$form.BackColor       = [System.Drawing.Color]::White

# --- target window picker ---
$lblPage          = New-Object System.Windows.Forms.Label
$lblPage.Text     = "Page to search:"
$lblPage.Location = New-Object System.Drawing.Point(12, 14)
$lblPage.Size     = New-Object System.Drawing.Size(95, 20)
$lblPage.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($lblPage)

$cmbWindow           = New-Object System.Windows.Forms.ComboBox
$cmbWindow.Location  = New-Object System.Drawing.Point(108, 11)
$cmbWindow.Size      = New-Object System.Drawing.Size(230, 24)
$cmbWindow.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbWindow.DropDownStyle = 'DropDownList'
$cmbWindow.DropDownWidth = 520
$form.Controls.Add($cmbWindow)

$btnRefresh          = New-Object System.Windows.Forms.Button
$btnRefresh.Text     = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(344, 10)
$btnRefresh.Size     = New-Object System.Drawing.Size(62, 25)
$btnRefresh.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($btnRefresh)

# --- search box ---
$txt          = New-Object System.Windows.Forms.TextBox
$txt.Location = New-Object System.Drawing.Point(12, 46)
$txt.Size     = New-Object System.Drawing.Size(285, 32)
$txt.Font     = New-Object System.Drawing.Font("Segoe UI", 14)
$form.Controls.Add($txt)

$btnSearch          = New-Object System.Windows.Forms.Button
$btnSearch.Text     = "Search"
$btnSearch.Location = New-Object System.Drawing.Point(306, 45)
$btnSearch.Size     = New-Object System.Drawing.Size(100, 33)
$form.Controls.Add($btnSearch)

$btnSlim          = New-Object System.Windows.Forms.Button
$btnSlim.Text     = "Shrink"
$btnSlim.Location = New-Object System.Drawing.Point(12, 86)
$btnSlim.Size     = New-Object System.Drawing.Size(65, 26)
$btnSlim.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($btnSlim)

$btnTestGrid          = New-Object System.Windows.Forms.Button
$btnTestGrid.Text     = "Test grid"
$btnTestGrid.Location = New-Object System.Drawing.Point(83, 86)
$btnTestGrid.Size     = New-Object System.Drawing.Size(70, 26)
$btnTestGrid.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($btnTestGrid)

$hint          = New-Object System.Windows.Forms.Label
$hint.Text     = "Type a part number and press Enter"
$hint.Location = New-Object System.Drawing.Point(160, 90)
$hint.Size     = New-Object System.Drawing.Size(250, 20)
$hint.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$hint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($hint)

$lbl          = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point(12, 120)
$lbl.Size     = New-Object System.Drawing.Size(400, 62)
$lbl.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($lbl)

function Say([string]$m, $c) { $lbl.ForeColor = $c; $lbl.Text = $m; $form.Refresh() }

# ---- populate the window picker --------------------------------------
# The combo holds plain strings and $script:pickHandles holds the matching
# handles at the same index, so the selection survives duplicate titles.
# Index 0 is always the auto-match fallback.
$script:pickHandles = @([IntPtr]::Zero)

function Refresh-WindowList {
    $prev = $script:pickedHwnd

    $cmbWindow.Items.Clear()
    $script:pickHandles = @([IntPtr]::Zero)
    $null = $cmbWindow.Items.Add("(auto) any window titled '$WindowMatch'")

    foreach ($w in Get-PickableWindows) {
        $t = $w.Title
        if ($t.Length -gt 90) { $t = $t.Substring(0, 90) + '...' }
        $null = $cmbWindow.Items.Add($t)
        $script:pickHandles += $w.Hwnd
    }

    $idx = 0
    if ($prev -ne [IntPtr]::Zero) {
        for ($i = 1; $i -lt $script:pickHandles.Count; $i++) {
            if ($script:pickHandles[$i] -eq $prev) { $idx = $i; break }
        }
    }
    $cmbWindow.SelectedIndex = $idx
}

$cmbWindow.Add_SelectedIndexChanged({
    $i = $cmbWindow.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:pickHandles.Count) {
        $script:pickedHwnd = $script:pickHandles[$i]
    }
})

$btnRefresh.Add_Click({
    Refresh-WindowList
    Say "Window list refreshed." ([System.Drawing.Color]::Black)
})

# ---- launch the bundled test grid ------------------------------------
$btnTestGrid.Add_Click({
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $gridPath = Join-Path $root 'Test-Grid.ps1'
    if (-not (Test-Path $gridPath)) {
        Say "Test-Grid.ps1 not found next to this script." ([System.Drawing.Color]::Firebrick)
        return
    }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $gridPath)
    Start-Sleep -Milliseconds 1200
    Refresh-WindowList

    for ($i = 1; $i -lt $cmbWindow.Items.Count; $i++) {
        if ($cmbWindow.Items[$i] -like '*Test Grid*') { $cmbWindow.SelectedIndex = $i; break }
    }

    Say "Test grid opened and selected. Try KELECRES-1006483A0." ([System.Drawing.Color]::ForestGreen)
    $form.TopMost = $true
    $txt.Focus()
})

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
        $form.Size = New-Object System.Drawing.Size(430, 232)
        $btnSlim.Text = "Shrink"
        $script:slim = $false
    } else {
        $form.Size = New-Object System.Drawing.Size(430, 124)
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
})

$form.Add_Shown({
    Refresh-WindowList
    $txt.Focus()
    $eng = Get-OcrEngine
    if ($eng) {
        Say "Ready. Pick the page to search, type a part number, press Enter." ([System.Drawing.Color]::ForestGreen)
    } else {
        Say "Windows OCR is not available on this PC.`nSettings > Apps > Optional features > English OCR." ([System.Drawing.Color]::Firebrick)
    }
})

Write-Host ""
Write-Host "Find Part (OCR) is running. Close its window to stop." -ForegroundColor Green
Write-Host ""

[System.Windows.Forms.Application]::Run($form)
