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
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
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
    # Our own always-on-top search box holds the very term we are looking
    # for, so leaving it visible would let OCR read it back and report a
    # false match. Go transparent for the duration of the grab.
    $hidden = $false
    if ($script:uiForm -and -not $script:uiForm.IsDisposed -and $script:uiForm.Opacity -gt 0) {
        $script:uiForm.Opacity = 0
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
        $hidden = $true
    }

    $shot = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($shot)
    $g.CopyFromScreen($left, $top, 0, 0, $shot.Size)
    $g.Dispose()

    if ($hidden) {
        $script:uiForm.Opacity = 1
        [System.Windows.Forms.Application]::DoEvents()
    }

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
        $statusLbl.Text = "No target window. Pick one from the dropdown."
        return
    }
    $script:targetHwnd = $hwnd

    # Bring the target forward so nothing is covering the grid we OCR.
    $SW_RESTORE = 9
    if ([Win]::IsIconic($hwnd)) {
        [Win]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 250
    }
    [Win]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 120

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
$script:uiForm        = $form

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
    if ($script:overlayForm -and -not $script:overlayForm.IsDisposed) {
        $script:overlayForm.Close()
    }
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
