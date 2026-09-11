# ============================================================
#  IMR PART SEARCH   -   STEP 2 of 2
# ============================================================
#  A small always-on-top search box. Type or scan a part number,
#  it finds that row in IMR's grid, scrolls to it and selects it.
#  You then click the row and carry on as normal.
#
#  WHAT THIS DOES NOT DO:
#    - does not install anything
#    - does not modify IMR
#    - does not write to any database
#    - does not click, save, or print anything
#  It reads the screen and moves the selection. That is all.
#
#  BEFORE RUNNING: run 01-probe.ps1 first and fill in the
#  CONFIG block below with what it tells you.
# ============================================================

# ==================== CONFIG ====================
$WindowMatch  = 'Incoming'   # word from IMR's title bar
$PartField    = 0            # field number holding the part number, -1 = whole row
$PartialMatch = $true        # $true: typing 1234 finds ABC-1234-X
# ================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
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
function AccSelect($o,[int]$id)    { try { [System.__ComObject].InvokeMember("accSelect",$BF::InvokeMethod,$null,$o,@(3,$id)) | Out-Null; $true } catch { $false } }

$script:gridAcc    = $null
$script:gridRows   = 0
$script:targetHwnd = [IntPtr]::Zero
$script:cache      = $null
$script:lastTerm   = ''
$script:lastIdx    = -1

function Connect-Target {
    $script:gridAcc = $null
    $t = $null
    foreach ($h in [Acc]::Tops()) {
        $ti = [Acc]::Title($h)
        if ($ti -and $ti -match $WindowMatch) { $t = $h; break }
    }
    if (-not $t) { return "IMR window not found. Is it open?" }
    $script:targetHwnd = $t

    $bestAcc = $null; $bestN = 3
    foreach ($k in [Acc]::Kids($t)) {
        $a = [Acc]::FromWindow($k)
        if (-not $a) { continue }
        $n = AccCount $a
        if ($n -gt $bestN) { $bestN = $n; $bestAcc = $a }
    }
    if (-not $bestAcc) { return "Found IMR but could not read its grid." }

    $script:gridAcc  = $bestAcc
    $script:gridRows = $bestN
    $script:cache    = $null
    return $null
}

function Build-Cache {
    $rows = @()
    for ($i = 1; $i -le $script:gridRows; $i++) {
        $v = AccProp $script:gridAcc "accValue" $i
        if (-not $v) { $v = AccProp $script:gridAcc "accName" $i }
        $rows += [pscustomobject]@{ Id = $i; Text = [string]$v }
    }
    $script:cache = $rows
}

function Get-PartText([string]$rowText) {
    if ($PartField -lt 0) { return $rowText }
    $p = $rowText -split ';'
    if ($PartField -lt $p.Count) { return $p[$PartField] }
    return $rowText
}

# ---- UI --------------------------------------------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "Find Part   (Ctrl+Shift+F to recall)"
$form.Size            = New-Object System.Drawing.Size(400, 180)
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
$txt.Size     = New-Object System.Drawing.Size(255, 32)
$txt.Font     = New-Object System.Drawing.Font("Segoe UI", 14)
$form.Controls.Add($txt)

$btnNext          = New-Object System.Windows.Forms.Button
$btnNext.Text     = "Next"
$btnNext.Location = New-Object System.Drawing.Point(276, 13)
$btnNext.Size     = New-Object System.Drawing.Size(65, 33)
$form.Controls.Add($btnNext)

$btnReload          = New-Object System.Windows.Forms.Button
$btnReload.Text     = "Reload grid"
$btnReload.Location = New-Object System.Drawing.Point(12, 54)
$btnReload.Size     = New-Object System.Drawing.Size(95, 26)
$btnReload.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($btnReload)

$btnSlim          = New-Object System.Windows.Forms.Button
$btnSlim.Text     = "Shrink"
$btnSlim.Location = New-Object System.Drawing.Point(113, 54)
$btnSlim.Size     = New-Object System.Drawing.Size(65, 26)
$btnSlim.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($btnSlim)

$hint          = New-Object System.Windows.Forms.Label
$hint.Text     = "Reload after a new order"
$hint.Location = New-Object System.Drawing.Point(186, 58)
$hint.Size     = New-Object System.Drawing.Size(190, 20)
$hint.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$hint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($hint)

$lbl          = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point(12, 88)
$lbl.Size     = New-Object System.Drawing.Size(370, 52)
$lbl.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($lbl)

function Say([string]$m, $c) { $lbl.ForeColor = $c; $lbl.Text = $m; $form.Refresh() }

$doFind = {
    param($fromNext)
    $term = $txt.Text.Trim()
    if (-not $term) { return }

    if (-not $script:gridAcc) {
        $e = Connect-Target
        if ($e) { Say $e ([System.Drawing.Color]::Firebrick); return }
    }
    if (-not $script:cache) {
        Say "Reading grid..." ([System.Drawing.Color]::Black)
        Build-Cache
    }

    $start = 0
    if ($fromNext -and $term -eq $script:lastTerm -and $script:lastIdx -ge 0) { $start = $script:lastIdx + 1 }

    $t = $term.ToUpper()
    $hit = -1; $total = 0
    for ($i = 0; $i -lt $script:cache.Count; $i++) {
        $p = (Get-PartText $script:cache[$i].Text).ToUpper()
        $m = if ($PartialMatch) { $p.Contains($t) } else { $p.Trim() -eq $t }
        if ($m) { $total++; if ($hit -lt 0 -and $i -ge $start) { $hit = $i } }
    }
    if ($hit -lt 0 -and $total -gt 0) {
        for ($i = 0; $i -lt $script:cache.Count; $i++) {
            $p = (Get-PartText $script:cache[$i].Text).ToUpper()
            $m = if ($PartialMatch) { $p.Contains($t) } else { $p.Trim() -eq $t }
            if ($m) { $hit = $i; break }
        }
    }

    if ($hit -lt 0) { Say "No match in $($script:cache.Count) rows." ([System.Drawing.Color]::Firebrick); return }

    $script:lastTerm = $term
    $script:lastIdx  = $hit
    $row = $script:cache[$hit]

    [Acc]::SetForegroundWindow($script:targetHwnd) | Out-Null
    Start-Sleep -Milliseconds 60
    $ok = AccSelect $script:gridAcc $row.Id
    $form.TopMost = $true

    $part = (Get-PartText $row.Text).Trim()
    if ($ok) {
        Say "$part`nRow $($row.Id) of $($script:cache.Count)    ($total match(es))" ([System.Drawing.Color]::ForestGreen)
    } else {
        Say "$part`nFound at row $($row.Id) but could not move the selection." ([System.Drawing.Color]::DarkOrange)
    }
    $txt.SelectAll(); $txt.Focus()
}

$txt.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $doFind $false } })
$btnNext.Add_Click({ & $doFind $true })
$btnReload.Add_Click({
    $e = Connect-Target
    if ($e) { Say $e ([System.Drawing.Color]::Firebrick); return }
    Build-Cache
    Say "Reloaded. $($script:cache.Count) rows." ([System.Drawing.Color]::ForestGreen)
})

# ---- shrink to just the search box -----------------------------------
$script:slim = $false
$btnSlim.Add_Click({
    if ($script:slim) {
        $form.Size = New-Object System.Drawing.Size(400, 180)
        $btnSlim.Text = "Shrink"
        $script:slim = $false
    } else {
        $form.Size = New-Object System.Drawing.Size(400, 92)
        $btnSlim.Text = "Expand"
        $script:slim = $true
    }
})

# ---- global recall hotkey: Ctrl + Shift + F --------------------------
# Polls rather than registering, so nothing needs cleaning up on exit.
$script:hotHeld = $false
$hotTimer          = New-Object System.Windows.Forms.Timer
$hotTimer.Interval = 150
$hotTimer.Add_Tick({
    $ctrl  = ([Acc]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0   # Ctrl
    $shift = ([Acc]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0   # Shift
    $f     = ([Acc]::GetAsyncKeyState(0x46) -band 0x8000) -ne 0   # F

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
$form.Add_FormClosing({ $hotTimer.Stop() })

$form.Add_Shown({
    $txt.Focus()
    $e = Connect-Target
    if ($e) { Say $e ([System.Drawing.Color]::Firebrick) }
    else { Say "Connected. $script:gridRows rows.`nType a part number and press Enter." ([System.Drawing.Color]::ForestGreen) }
})

Write-Host ""
Write-Host "Find Part is running. Close its window to stop." -ForegroundColor Green
Write-Host ""

[System.Windows.Forms.Application]::Run($form)
