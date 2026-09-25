# IMR Part Number Search

A separate helper that lets an operator type a part number and have
Opcenter IPL Incoming Material Registration jump straight to that row,
instead of scrolling to find it.

---

## The problem

Part arrives, operator has to scroll the IMR grid to find its row, clicks
the row, adjusts details in the popup, prints the sticker. Everything
except the finding step already works. There is no search or filter on
that screen.

## Why the obvious routes are closed

Checked against the Siemens 2410 manuals for IPL:

| Route | Status | Reason |
|---|---|---|
| Built in search or filter | Not available | No mention in the General User, API Reference, or Web Application guides. The Storage app documents a Filter button and sortable headers; IMR documents neither. |
| IMR plugins | Cannot help | The four plugins (`AttributePluginSelector`, `AttributeAdvPluginSelector`, `ValidatorPlugin`, `ChangePartNumberPlugin`) are data logic hooks. None can add a UI control. |
| REST API | Cannot help for this screen | There is a POST to create a purchase order but no GET to read one. The list being scrolled is not exposed. |
| IPL Searcher | Separate application | No documented link back into IMR's registration dialog. |
| Vendor change | Declined | Software provider said they cannot do anything. |

## Two approaches

### Approach A — MSAA accessibility (scripts 01 & 02)

Uses the Windows accessibility layer (oleacc.dll MSAA) to read the grid
text and move the selection. Works perfectly on standard WinForms grids.

**Limitation:** IMR's grid may be owner-drawn, meaning it paints the cell
text itself and the accessibility layer returns empty strings even though
it can count the rows. If the probe (01) reports BUILDABLE and shows real
data, use this approach — it is faster and simpler.

### Approach B — OCR (scripts 03 & 04)

Falls back to screenshotting the grid and reading it with the **built-in
Windows OCR engine** (`Windows.Media.Ocr`). This is the fallback when
MSAA returns no text — the app must paint the pixels, so OCR always has
something to read.

- Screenshots the grid region
- Upscales and optionally boosts contrast before OCR
- Searches the recognised text for the part number
- If not on screen, scrolls one page and re-scans, repeating until found
  or the bottom is reached
- Moves the mouse onto the matching row and clicks it, selecting that
  row in IMR

**Hard constraint:** stock Windows only. No Tesseract, no Python, no
installs. Only `System.Drawing`, `System.Windows.Forms`, and
`Windows.Media.Ocr` as they ship on Windows 10/11.

---

## Files

| File | What it does |
|---|---|
| `01-probe.ps1` | MSAA approach: read-only probe, reports whether the grid is readable and prints config values |
| `02-part-search.ps1` | MSAA approach: always-on-top search box, finds and selects the matching row |
| `03-ocr-spike.ps1` | OCR approach: Phase 0 feasibility test — screenshots the grid, runs Windows OCR once, prints raw results |
| `04-ocr-search.ps1` | OCR approach: full search tool with window picker, scrolling, and click-the-row |
| `Test-Grid.ps1` | A fake 25-row grid for trying the tool without IMR |

### Double-click launchers

| Launcher | Runs |
|---|---|
| `IMR-Part-Search.bat` | **The OCR tool. This is the only file you need to open.** |
| `Run-Probe.bat` | The MSAA probe (01) |
| `Run-Search-MSAA.bat` | The MSAA search tool (02) |
| `Run-OCR-Spike.bat` | The OCR feasibility spike (03) |

---

## Which approach to use

1. Run `01-probe.ps1` first. If it reports **BUILDABLE** with real row
   data, use `02-part-search.ps1` — it is instant and reliable.
2. If the probe reports **NOT BUILDABLE**, or shows rows with empty text,
   switch to the OCR path.
3. Run `03-ocr-spike.ps1` to confirm the OCR engine can read the part
   numbers cleanly.
4. If the spike passes, use `04-ocr-search.ps1` for daily operation.

---

## Step-by-step: MSAA approach (01 → 02)

1. Open IMR and load an order so the part number table has rows on screen.
2. Open Windows PowerShell: Start menu, type `powershell`, press Enter.
3. Open `01-probe.ps1` in Notepad. Ctrl+A, Ctrl+C.
4. Right click inside the PowerShell window to paste. Press Enter.

### Reading the probe result

**`RESULT: BUILDABLE`** — the grid is readable. It prints the three
config values for step 2, plus the row count. Continue to `02-part-search.ps1`.

**`RESULT: NOT BUILDABLE`** — no control exposed more than 3 rows. Switch
to the OCR approach (03 → 04).

### Running the search (02)

1. Open `02-part-search.ps1` in Notepad.
2. In the CONFIG block near the top, set the three values the probe printed.
3. Save.
4. With IMR open and an order loaded, paste the file into PowerShell.

A small box appears. Type or scan a part number, press Enter. IMR jumps
to that row and selects it.

- **Next** — steps through multiple matches for partial searches
- **Reload grid** — press after loading a different order
- **Scroll mode** — tick if the probe reported fewer rows than the order
  actually contains
- **Shrink** — collapses the window to just the search box
- **Ctrl+Shift+F** — brings it back from minimized, from anywhere

---

## Step-by-step: OCR approach (03 → 04)

### Phase 0 — feasibility spike (03)

1. Open IMR with an order loaded.
2. Open `03-ocr-spike.ps1` in Notepad. Ctrl+A, Ctrl+C.
3. Right click inside PowerShell to paste. Press Enter.
4. You get a 4-second countdown — click the IMR window during it.
5. The script screenshots the window, runs OCR, and prints every word
   it found, with bounding boxes.

**What to check:** find a real part number in the output. Is it intact,
or are characters swapped (0/O, 1/I/l, 5/S, 8/B)?

- **Clean** — the project is viable. Use `04-ocr-search.ps1`.
- **Mangled** — raise `$Upscale` to 3, or set `$Contrast` to 1.4, and
  run again. Stay inside stock Windows.

The spike saves the captured image to `%TEMP%\imr-ocr-spike.png` so you
can see exactly what OCR saw.

### Running the search (04)

**Double-click `IMR-Part-Search.bat`.** That is the whole thing — one
file, nothing else to start.

The window has a **Page to search** dropdown at the top listing every
open window. Pick the one holding the grid:

- Leave it on **(auto)** and it finds any window whose title contains
  `Incoming`, which is the normal IMR case.
- Or pick IMR explicitly from the list if the title differs.
- **Refresh** rescans the list after you open or close a window.

Then type a part number and press Enter. The tool:
- Brings the selected window to the front and drops its own search box
  behind it (so the box isn't in the screenshot, isn't under the
  pointer, and can't swallow the click)
- Screenshots the window and runs OCR
- If the part isn't on screen, scrolls the grid and re-scans
- **Moves the mouse onto the matching row and clicks it**, so IMR
  selects that row exactly as if you had clicked it by hand

Press **Esc** to abort a long search.

### How scrolling works

The rows live in a *child* control inside the window. Posting
`WM_MOUSEWHEEL` or `WM_VSCROLL` to the top-level window scrolls
nothing, because those messages never reach the control that owns the
scrollbar — and in an owner-drawn grid there's no reliable way to find
that control.

So the tool parks the real mouse pointer over the grid and emits a real
wheel event. Windows routes it to whatever is under the pointer, exactly
as if you'd spun the wheel yourself, which works no matter how the grid
is built.

There is also no dependable way to jump straight to the top. Instead the
tool sweeps **down to the bottom, then back up to the top**. Those two
passes together cover the whole grid from wherever you happened to be
sitting, without needing an absolute position. It knows it has reached an
end when a scroll stops changing what OCR reads.

- `$WheelNotches` — how far each scroll step moves (default 5 notches,
  roughly 15 rows). **Lower it if rows get skipped between scans**;
  raise it to sweep long orders faster.
- `$MaxPages` — safety limit on scroll steps, applied to each pass
  separately.

- **Fuzzy OCR** (`$FuzzyOCR = $true`) — treats common OCR confusable
  characters (0/O, 1/I/l, 5/S, 8/B) as equivalent when matching
- **Ctrl+Shift+F** — recalls the window from anywhere

### About the click

A misplaced click in IMR could hit *Print Labels* or *Clear*, so the
click is guarded three ways. It is skipped, with a message, unless:

1. The target point lies inside the window that was captured.
2. That window is genuinely the thing drawn at that point — nothing is
   covering it.
3. The pointer actually reached the requested position.

The tool issues exactly one left click and nothing else. It never
types and never presses a button.

**While you are still confirming it aims correctly, set
`$AutoClick = $false`** in the CONFIG block. The tool then only parks
the mouse pointer on the row it found and leaves the clicking to you —
all the benefit of the search, none of the risk of a stray click.

> **Coordinates and display scaling.** The script calls
> `SetProcessDPIAware()` at startup so the pixel it screenshots and the
> pixel it clicks are the same point. Without that, Windows virtualises
> coordinates on a scaled display (125%, 150%) and the aim drifts down
> the grid. If you ever see it miss by a consistent number of rows,
> display scaling is the first thing to suspect.

---

## Honest caveats

- **Unsupported.** Siemens did not sanction this. It is a workaround.
- **Fragile to updates.** It depends on IMR's window layout. An update
  can break it with no warning.
- **It clicks.** The OCR tool moves the mouse and left-clicks the row
  it matched, which is a real input event — the same one a hand would
  produce. It selects a row and nothing more: it never types, never
  saves, and never presses Print. Set `$AutoClick = $false` to reduce
  it to a pointer aid that clicks nothing.
- **A wrong match means a wrong row selected.** OCR can misread a
  character. The guards stop the click landing outside the grid, but
  they cannot tell a correctly-aimed click on the wrong row from a
  right one. The operator should still confirm the selected row before
  acting on it.
- **Per machine.** It runs on each PC where needed. Nothing installed,
  but the file must be available there.
- **OCR approach is slower.** A few seconds per screen, plus scrolling
  time for long orders. Fine for typical use.
- **OCR approach depends on screen rendering.** Zoom changes, DPI
  changes, or theme changes can affect accuracy. Re-run the spike (03)
  after any such change.

---

## Where the screenshots go

Short answer: **nowhere.** The daily tool (`04-ocr-search.ps1`) never
writes an image to disk, and nothing in this repo makes a network call
of any kind.

The capture path is entirely in memory:

1. `CopyFromScreen` draws the window into a `System.Drawing.Bitmap` in RAM.
2. It is encoded into a `MemoryStream`, then an
   `InMemoryRandomAccessStream` — both RAM only, as the names say.
3. `Windows.Media.Ocr` reads that and returns text plus bounding boxes.
4. Every buffer is **overwritten with zeros and then released**, in a
   `finally` block, on all paths including errors.

Nothing is cached between searches, written to a log, or put on the
clipboard.

### Why zeroing, and not just disposing

`Dispose()` hands memory back to the allocator; it does not erase it.
The pixels stay readable in that freed block until something else
happens to reuse it. So each copy of the screen is zeroed first:

| Copy of the screen | How it is wiped |
|---|---|
| Raw `CopyFromScreen` bitmap | `LockBits` + zero fill, then dispose |
| Upscaled/contrast-boosted bitmap | `LockBits` + zero fill, then dispose |
| Encoded BMP byte array | `Array.Clear` |
| `MemoryStream`'s internal array | `Array.Clear` on `GetBuffer()` |
| Decoded `SoftwareBitmap` (what OCR reads) | `IMemoryBufferByteAccess` + zero fill — **best effort**, see below |

The page text is **never retained**. Scroll detection only needs to
know whether a page reads the same as the last one, so the tool keeps a
SHA-256 fingerprint instead of the text — 32 bytes that cannot be read
back into order data. After each search it forces a GC pass so the
zeroed blocks are reclaimed immediately rather than eventually.

The search box and the result line are blanked `$ClearAfterSec` seconds
after a search (default 30), so a part number and the row it matched
are not left on screen after the operator walks away.

### What is *not* guaranteed

Be straight about this if someone asks:

- **The `SoftwareBitmap` wipe is best effort.** Reaching a WinRT buffer
  needs COM interop that can fail on some Windows builds. It is wrapped
  in a `try`/`catch`; if it fails, that one decoded copy goes back to
  the allocator unwiped, and every other copy is still zeroed.
- **Managed strings cannot be scrubbed.** The recognised text and the
  term you type are .NET strings — immutable, moved by the GC, with no
  supported way to overwrite them. They are dropped promptly, but
  "dropped" is the honest word, not "erased".
- **Paging is outside the script's control.** Windows may write any of
  this memory to the pagefile, or to `hiberfil.sys` on sleep, before it
  is wiped. Preventing that needs `VirtualLock` on every buffer, which
  GDI+ and WinRT do not expose.
- **The OS may capture the screen independently.** Clipboard history,
  Windows Recall on Copilot+ PCs, DLP/endpoint agents and screen
  recorders all see the same pixels regardless of what this tool does.
- **Any process running as the same user can read this process's
  memory.** That is a Windows property, not something a script can fix.

None of that is an argument against the tool — it is the same footing
as IMR itself, which has the data on screen either way. It is just the
set of claims that will not survive a determined reviewer, so do not
make them.

**The OCR engine is on-device.** `Windows.Media.Ocr` is the local
recognition engine built into Windows 10/11. It is not, and does not
call, a cloud service.

### The one exception

`03-ocr-spike.ps1` — the diagnostic you run once to check OCR
legibility — **does** save a PNG, by design, so you can see what OCR
saw:

```
%TEMP%\imr-ocr-spike.png
```

That file **persists until something deletes it**, and on a real IMR
window it is a picture containing live order data. The script now
prints its location and the delete command when it finishes. To avoid
writing it at all, set `$SaveShot = ''` at the top of that script.

Nothing else in this repo writes an image anywhere.

### The startup cache

To start faster, the search tool compiles its small block of C# helper
code once and saves it as a DLL under
`%LOCALAPPDATA%\IMRPartSearch\helpers-<hash>.dll`. Later launches load
that instead of recompiling, which saves a few seconds each time.

- It contains **only the tool's own code** — no screenshots, no text,
  no order data.
- The `<hash>` is a fingerprint of the source, so an updated script
  never loads an old helper; it compiles a fresh one alongside.
- Delete the folder at any time; the next launch rebuilds it. If the
  folder can't be written, the tool silently falls back to compiling
  in memory as before.
- It sits in a folder only your user can write to, so it adds no
  exposure beyond the script file itself, which that same user can
  already edit.

---

## What to tell quality / IT

This tool reads the screen and (in OCR mode) moves the mouse wheel and
the mouse pointer, and issues a single left click to select the row it
found — the same input an operator's hand produces, and nothing beyond
it. It does not read the database, does not read IMR's memory, and does
not modify IMR or any data. It makes no network calls whatsoever, and
the screenshots it takes are held in memory for a single OCR call and
then released — none are written to disk (see **Where the screenshots
go** above for the one diagnostic exception). It uses only software that
ships with a standard Windows PC — the built-in OCR engine and built-in
.NET, run from the PowerShell that is already on the machine. Nothing is
installed or downloaded. Besides the script files, the only thing it
writes is a small cache of its own compiled helper code, which contains
no screen content or data (see **The startup cache** above).

---

## Cheaper alternatives worth ruling out first

Both cost nothing and may remove the problem entirely.

1. **Shorten the purchase orders.** The list being scrolled is the line
   items of one loaded PO. If POs arrive with hundreds of lines,
   splitting them at the ERP/SAP end collapses the scroll.

2. **Check whether the Part Number column header sorts.** Not documented
   for IMR, but it is documented for the Storage app. One click to test.

## Also worth asking

3. Open **Component Manager** on the IMR PC. Is **IPL Searcher** in the
   list of available applications?

4. Can we get a KeyCloak `ipl_user` account? Read only, GET calls only.
