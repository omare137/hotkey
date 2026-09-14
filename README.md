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

## What this is instead

A small always-on-top window running alongside IMR. It reads IMR's grid
through the Windows accessibility layer (the same layer screen readers
use), finds the matching row, and moves IMR's selection to it. The
operator then clicks the row and continues as normal.

It does not install anything, modify IMR, or touch the database.

**Proven on a test grid:** all rows were readable from outside the
program, including rows scrolled out of view, and the selection moved
correctly. Whether real IMR behaves the same is what step 1 below
determines.

---

## Step 1 — probe (read only, 5 minutes)

1. Open IMR and load an order so the part number table has rows on screen.
2. Open Windows PowerShell: Start menu, type `powershell`, press Enter.
3. Open `01-probe.ps1` in Notepad. Ctrl+A, Ctrl+C.
4. Right click inside the PowerShell window to paste. Press Enter.

Do not double click the .ps1 file. Windows blocks that by default.
Copy and paste is the way around it.

### Reading the result

**`RESULT: BUILDABLE`** — the grid is readable. It prints the three
config values for step 2, plus the row count. Continue.

**`RESULT: NOT BUILDABLE`** — no control exposed more than 3 rows. IMR's
grid is custom drawn, Windows cannot read it, and no external tool can.
This is a definite answer. Stop here and report it.

**`Could not find a window matching`** — it lists the open windows.
Find IMR, take a distinctive word from its title, and change the
`$WindowMatch` line at the top of the file. Run again.

### One thing to check either way

The probe reports how many rows the grid exposed. Compare that to how
many parts are actually in the order you loaded.

- Same number → all rows readable, search is instant.
- Much smaller → only on-screen rows are exposed. The tool needs a
  scrolling mode, which is slower but still works. Report the two numbers.

---

## Step 2 — the tool

1. Open `02-part-search.ps1` in Notepad.
2. In the CONFIG block near the top, set the three values the probe printed.
3. Save.
4. With IMR open and an order loaded, paste the file into PowerShell the
   same way as before.

A small box appears in the top left. Type or scan a part number, press
Enter. IMR jumps to that row and selects it.

- **Next** — steps through multiple matches when searching a partial
  number like `CAP`.
- **Reload grid** — press after loading a different order, so it
  re-reads the new rows.
- **Scroll mode** — tick this only if the probe reported far fewer rows
  than the order actually contains. Instead of reading everything up
  front, it pages the grid from the top and checks each screenful until
  it finds a match. Slower, a second or two on a long order, but it
  reaches rows that are not otherwise exposed. Leave it off if the row
  counts matched; normal mode is instant.
- **Shrink** — collapses the window down to just the search box.
- **Minimize** — normal minimize button, sends it to the taskbar.
- **Ctrl + Shift + F** — brings it back from minimized and puts the
  cursor in the box, from anywhere. Works while IMR has focus, so the
  operator never has to go hunting for the taskbar.

---

## Honest caveats

State these up front rather than after.

- **Unsupported.** Siemens did not sanction this. It is a workaround.
- **Fragile to updates.** It depends on IMR's internal window structure.
  An IMR update can break it with no warning. Whoever inherits it needs
  to know that, otherwise a future outage looks mysterious.
- **Operator aid only.** It reads the screen and moves the selection. It
  deliberately does not click, save, or print. Every action that changes
  data stays with the operator.
- **Per machine.** It runs on each PC where it is needed. Nothing is
  installed, but the file has to be available there.

---

## Cheaper alternatives worth ruling out first

Both cost nothing and may remove the problem entirely.

1. **Shorten the purchase orders.** The list being scrolled is the line
   items of one loaded PO. If POs arrive with hundreds of lines,
   splitting them at the ERP/SAP end (one per delivery, pallet, or
   supplier) collapses the scroll. This is a process change, not a
   software one.

2. **Check whether the Part Number column header sorts.** Not documented
   for IMR, but it is documented for the Storage app. One click to test.

## Also worth asking

3. Open **Component Manager** on the IMR PC. Is **IPL Searcher** in the
   list of available applications? If it is, the component exists on site
   and only needs a Resource ID configured. If not, it was never installed.

4. Can we get a KeyCloak `ipl_user` account? Read only, GET calls only,
   and per the API guide it requires no additional software installed on
   the server. Useful regardless of which direction this goes.
