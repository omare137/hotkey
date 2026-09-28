# ============================================================
#  IMR OCR SPIKE   -   PHASE 0  (feasibility test)
# ============================================================
#  The single most important test in the whole project.
#  It screenshots the IMR grid, runs the BUILT-IN Windows OCR
#  engine on it once, and prints every word it read together
#  with where on screen that word sits.
#
#  What you are checking: can Windows OCR read the part numbers
#  cleanly? If KELECRES-1006483A0 comes back intact, the project
#  is alive. If it is mangled (0/O, 1/I/l, 5/S, 8/B confusions),
#  the fix stays inside stock Windows -- upscale the capture,
#  boost contrast, narrow to one column. No Tesseract, no installs.
#
#  STOCK WINDOWS ONLY. Installs nothing. Reads pixels only.
#  Does not touch IMR, its memory, or any database.
#
#  HOW TO RUN: open Windows PowerShell (Start menu, type
#  "powershell"). Open this file in Notepad, Ctrl+A, Ctrl+C,
#  then right click inside the PowerShell window and press Enter.
#  You get a 4 second countdown -- click the IMR window during it.
# ============================================================

# ---------- CONFIG ----------
# How much the capture is enlarged before OCR. 1 = no scaling.
# Small grid text reads far better at 2 or 3. Costs a little speed.
$Upscale = 2.0
# Boost contrast to help OCR separate text from grid lines. 1 = off.
$Contrast = 1.0
# Save the captured image so you can eyeball exactly what OCR saw.
#
# THIS IS THE ONLY PLACE EITHER TOOL WRITES A SCREENSHOT TO DISK, and
# the file stays there until something deletes it. It is a picture of
# whatever was on screen, so on a real IMR window it contains live
# order data. Set this to '' to keep the capture in memory only.
$SaveShot = "$env:TEMP\imr-ocr-spike.png"
# ----------------------------

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Language CSharp @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static string Title(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
}
"@

# ---- WinRT / Windows.Media.Ocr plumbing ------------------------------
# The built-in OCR engine is a WinRT component. PowerShell 5.1 can call
# it, but the async calls have to be pumped by hand. This Await helper
# turns a WinRT IAsyncOperation into something we can wait on.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($op, $resultType) {
    $asTask  = $asTaskGeneric.MakeGenericMethod($resultType)
    $netTask = $asTask.Invoke($null, @($op))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

# Load the WinRT types we need.
$null = [Windows.Media.Ocr.OcrEngine,               Windows.Media.Ocr,           ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,    Windows.Graphics.Imaging,    ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap,   Windows.Graphics.Imaging,    ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataWriter,        Windows.Storage.Streams,     ContentType = WindowsRuntime]

# Turn a System.Drawing.Bitmap into a WinRT SoftwareBitmap by encoding
# it to an in-memory stream and decoding it back. No temp files needed.
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

# ---- capture ---------------------------------------------------------
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  IMR OCR SPIKE  (Phase 0)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Click the IMR window now. Capturing in..." -ForegroundColor Yellow
foreach ($s in 4,3,2,1) { Write-Host "  $s" ; Start-Sleep -Seconds 1 }

$hwnd = [Win]::GetForegroundWindow()
$title = [Win]::Title($hwnd)
$rect = New-Object Win+RECT
[Win]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top

Write-Host ""
Write-Host "Captured window: $title" -ForegroundColor Green
Write-Host "  rect  ${w}x${h}  at ($($rect.Left),$($rect.Top))"
Write-Host ""

if ($w -le 0 -or $h -le 0) {
    Write-Host "That window has no usable size. Try again and click the IMR grid." -ForegroundColor Red
    return
}

$shot = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($shot)
$g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $shot.Size)
$g.Dispose()

# ---- optional upscale + contrast, all stock System.Drawing ----------
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

if ($SaveShot) {
    try { $proc.Save($SaveShot, [System.Drawing.Imaging.ImageFormat]::Png); Write-Host "Saved capture to $SaveShot" -ForegroundColor DarkGray } catch {}
}

# ---- run OCR ---------------------------------------------------------
Write-Host ""
Write-Host "Running built-in Windows OCR..." -ForegroundColor Cyan

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $engine) {
    Write-Host ""
    Write-Host "Windows OCR has no language pack available on this PC." -ForegroundColor Red
    Write-Host "It is normally present on Windows 10/11. Ask IT to add the"
    Write-Host "English OCR feature (Settings > Apps > Optional features)."
    return
}

$swBmp  = ConvertTo-SoftwareBitmap $proc
$result = Await ($engine.RecognizeAsync($swBmp)) ([Windows.Media.Ocr.OcrResult])

# ---- print raw results ----------------------------------------------
Write-Host ""
Write-Host "--- full recognised text ---" -ForegroundColor Cyan
Write-Host $result.Text
Write-Host ""
Write-Host "--- words with bounding boxes (coords are in the UPSCALED image) ---" -ForegroundColor Cyan

$wordCount = 0
foreach ($line in $result.Lines) {
    foreach ($word in $line.Words) {
        $r = $word.BoundingRect
        "  '{0}'  @ x={1} y={2} w={3} h={4}" -f $word.Text, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height | Write-Host
        $wordCount++
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Read $wordCount words on $($result.Lines.Count) lines." -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "THE TEST:" -ForegroundColor Yellow
Write-Host "Look for a real part number above. Is it intact, or are"
Write-Host "characters swapped (0/O, 1/I/l, 5/S, 8/B)?"
Write-Host "  Clean      -> the project is viable. Build Phase 1."
Write-Host "  Mangled    -> raise `$Upscale to 3, or set `$Contrast to 1.4,"
Write-Host "                and run again. Stay inside stock Windows."
Write-Host ""

$shot.Dispose()
if ($proc -ne $shot) { $proc.Dispose() }

if ($SaveShot -and (Test-Path $SaveShot)) {
    Write-Host "CLEAN UP:" -ForegroundColor Yellow
    Write-Host "A screenshot of that window is now sitting at:"
    Write-Host "  $SaveShot" -ForegroundColor White
    Write-Host "It will stay there until deleted. If the window held real"
    Write-Host "order data, delete it when you are done looking:"
    Write-Host "  Remove-Item '$SaveShot'" -ForegroundColor White
    Write-Host ""
}
