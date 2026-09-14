# ============================================================
#  IMR PROBE   -   STEP 1 of 2
# ============================================================
#  Finds IMR's part number grid and prints the settings you
#  need for step 2.
#
#  READ ONLY. Installs nothing. Clicks nothing. Changes nothing.
#  It does not write to IMR or to any database.
#
#  BEFORE RUNNING: open IMR and load an order, so the part
#  number table has rows visible on screen.
#
#  HOW TO RUN: open Windows PowerShell (Start menu, type
#  "powershell"). Open this file in Notepad, Ctrl+A, Ctrl+C,
#  then right click inside the PowerShell window and press Enter.
# ============================================================

# ---------- CONFIG ----------
# A word from IMR's title bar. Change if the probe cannot find it.
$WindowMatch = 'Incoming'
# ----------------------------

Add-Type -Language CSharp @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class Acc {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("oleacc.dll")] public static extern int AccessibleObjectFromWindow(
        IntPtr hwnd, uint dwId, ref Guid riid,
        [MarshalAs(UnmanagedType.IDispatch)] out object ppv);

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
    public static string Title(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
    public static string Cls(IntPtr h)   { StringBuilder sb = new StringBuilder(512); GetClassName(h, sb, 512);  return sb.ToString(); }
    public static object FromWindow(IntPtr h) {
        Guid iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
        object o = null;
        if (AccessibleObjectFromWindow(h, 0xFFFFFFFC, ref iid, out o) != 0) return null;
        return o;
    }
}
"@

$BF = [System.Reflection.BindingFlags]
function AccProp($o,[string]$m,$a) { try { [System.__ComObject].InvokeMember($m,$BF::GetProperty,$null,$o,@($a)) } catch { $null } }
function AccCount($o)              { try { [System.__ComObject].InvokeMember("accChildCount",$BF::GetProperty,$null,$o,@()) } catch { 0 } }

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  IMR PROBE" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# ---- 1. find the window ---------------------------------------------
$target = $null
foreach ($h in [Acc]::Tops()) {
    $t = [Acc]::Title($h)
    if ($t -and $t -match $WindowMatch) { $target = $h; break }
}

if (-not $target) {
    Write-Host "Could not find a window matching '$WindowMatch'." -ForegroundColor Red
    Write-Host ""
    Write-Host "Windows open right now:" -ForegroundColor Yellow
    foreach ($h in [Acc]::Tops()) { $t = [Acc]::Title($h); if ($t) { "    $t" } }
    Write-Host ""
    Write-Host "Find IMR in that list, pick one distinctive word from its title,"
    Write-Host "and change the \`\$WindowMatch line at the top of this file."
    return
}

$winTitle = [Acc]::Title($target)
Write-Host "Found window:" -ForegroundColor Green
Write-Host "   $winTitle"
Write-Host ""

# ---- 2. scan its controls -------------------------------------------
Write-Host "Scanning controls inside it..." -ForegroundColor Cyan
Write-Host ""

$cands = @()
$n = 0
foreach ($k in [Acc]::Kids($target)) {
    $n++
    $cls = [Acc]::Cls($k)
    $a   = [Acc]::FromWindow($k)
    $cnt = if ($a) { AccCount $a } else { -1 }
    "{0,3}  rows={1,-7} {2}" -f $n, $cnt, $cls | Write-Host
    if ($a -and $cnt -gt 3) { $cands += [pscustomobject]@{ Acc=$a; Count=$cnt; Cls=$cls } }
}

if (-not $cands) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "  RESULT: NOT BUILDABLE" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "No control exposed more than 3 accessible rows."
    Write-Host "IMR's grid is custom drawn, so Windows cannot read it and"
    Write-Host "no external tool can either."
    Write-Host ""
    Write-Host "This is a definite answer. Report it and stop here."
    return
}

$best = $cands | Sort-Object Count -Descending | Select-Object -First 1

# ---- 3. sample the rows ---------------------------------------------
Write-Host ""
Write-Host "Grid found with $($best.Count) rows." -ForegroundColor Green
Write-Host ""
Write-Host "--- sample rows ---" -ForegroundColor Cyan

$samples = @()
$max = [Math]::Min(8, $best.Count)
for ($i = 1; $i -le $max; $i++) {
    $v = AccProp $best.Acc "accValue" $i
    if (-not $v) { $v = AccProp $best.Acc "accName" $i }
    $samples += [string]$v
    "  row $i : $v" | Write-Host
}

# ---- 4. work out the part number field ------------------------------
Write-Host ""
Write-Host "--- fields within each row ---" -ForegroundColor Cyan

$dataRow = $samples | Where-Object { $_ -and $_ -match ';' } | Select-Object -First 1

if ($dataRow) {
    $fields = $dataRow -split ';'
    for ($f = 0; $f -lt $fields.Count; $f++) {
        "  field[{0}] = '{1}'" -f $f, $fields[$f] | Write-Host
    }
    Write-Host ""
    Write-Host "Find which field number holds the PART NUMBER above."
} else {
    Write-Host "  Rows are not semicolon separated on this system."
    Write-Host "  Use -1 for the part field, which searches the whole row."
}

# ---- 5. verdict ------------------------------------------------------
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  RESULT: BUILDABLE" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Open 02-part-search.ps1 and set these three lines:" -ForegroundColor Cyan
Write-Host ""
Write-Host "   \`\$WindowMatch = '$WindowMatch'"
if ($dataRow) {
    Write-Host "   \`\$PartField   = <the field number holding part numbers>"
} else {
    Write-Host "   \`\$PartField   = -1"
}
Write-Host "   \`\$PartialMatch = \`\$true"
Write-Host ""
Write-Host "ALSO CHECK THIS:" -ForegroundColor Yellow
Write-Host "The grid reported $($best.Count) rows. Compare that to how many"
Write-Host "parts are actually in the order you loaded."
Write-Host "  Same number      -> all rows readable, search will be instant."
Write-Host "  Much smaller     -> only on-screen rows are exposed. Tell me,"
Write-Host "                      the tool needs a scrolling mode."
Write-Host ""
