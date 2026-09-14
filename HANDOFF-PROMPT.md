# Handoff prompt

Paste everything below into Copilot when you are in the quality room.
Then paste the probe output underneath it.

---

I am adding a part number search to Siemens Opcenter IPL Incoming
Material Registration (IMR). Operators currently scroll a grid to find a
part, click the row, adjust details in a popup, and print a sticker. Only
the finding step is a problem.

## Already ruled out, do not suggest these

Checked against the Siemens 2410 manuals (IPL Material Management General
User Guide, IPL API Reference Guide, IPL Web Application User Guide):

- No built in search or filter on the IMR screen. Not documented anywhere.
  The Storage app has one; IMR does not.
- IMR plugins cannot add UI. The four plugins (AttributePluginSelector,
  AttributeAdvPluginSelector, ValidatorPlugin, ChangePartNumberPlugin)
  are data logic hooks only.
- The REST API has a POST to create a purchase order but no GET to read
  one, so the list being scrolled is not exposed.
- IPL Searcher is a separate application with no documented link into
  IMR's registration dialog.
- The software vendor was asked and said they cannot do anything.
- Print in IMR is a physical sticker/label printer, not a report.
- No export function.
- IT blocks installing browser extensions and most software.

## The approach that works

A separate PowerShell tool, running alongside IMR, that reads IMR's grid
through MSAA (oleacc.dll, AccessibleObjectFromWindow with OBJID_CLIENT
0xFFFFFFFC and IID_IAccessible 618736e0-3c3d-11cf-810c-00aa00389b71),
finds the row matching a typed part number, and calls accSelect with
flags 3 (TAKEFOCUS + TAKESELECTION) to scroll to it and select it. The
operator then clicks the row themselves.

Nothing is installed. IMR is not modified. No database writes. The tool
only reads and moves the selection.

## Important technical detail

The .NET UI Automation client (System.Windows.Automation) does NOT work
for this. On this environment it returns every WinForms control as a bare
Pane with zero supported patterns, even after loading and registering
UIAutomationClientsideProviders. Do not suggest UIAutomation,
AutomationElement, TreeWalker, or GridPattern. MSAA via oleacc.dll is the
layer that works. This was tested and confirmed.

Row data comes back from accValue as a single semicolon separated string,
for example: CON-87137-R;CON component rev E;500;250;No

## Working code

I have two PowerShell scripts that work, validated end to end against a
WinForms test grid:

- 01-probe.ps1 — read only, finds the grid, reports row count, prints
  sample rows with fields numbered
- 02-part-search.ps1 — always on top search box, finds and selects the
  row in the target program, has minimize, shrink, and a Ctrl+Shift+F
  recall hotkey

## What I need help with now

I am about to run the probe against real IMR. Below is its output.

Help me with:
1. Confirming whether the grid is readable
2. Working out which semicolon field holds the part number
3. Whether the row count matches the real number of lines in the loaded
   order, and if not, writing a scrolling mode that pages through the
   grid while searching
4. Fixing any errors in the output

Constraints: Windows PowerShell 5.1, pasted into the console (not run as
.ps1 files, execution policy blocks that). No installs. No admin rights
assumed. Read only wherever possible.

Probe output follows:
