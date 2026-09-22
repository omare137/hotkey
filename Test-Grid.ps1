Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form      = New-Object System.Windows.Forms.Form
$form.Text = "Incoming Material Registration - Test Grid"
$form.Size = New-Object System.Drawing.Size(900, 500)
$form.StartPosition = 'CenterScreen'

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Dock = 'Fill'
$dgv.ReadOnly = $true
$dgv.AllowUserToAddRows = $false
$dgv.SelectionMode = 'FullRowSelect'
$dgv.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$null = $dgv.Columns.Add("PartNumber", "Part Number")
$null = $dgv.Columns.Add("Description", "Description")
$null = $dgv.Columns.Add("Qty", "Qty")
$null = $dgv.Columns.Add("Received", "Received")
$null = $dgv.Columns.Add("Status", "Status")

$dgv.Columns["PartNumber"].Width = 200
$dgv.Columns["Description"].Width = 300
$dgv.Columns["Qty"].Width = 80
$dgv.Columns["Received"].Width = 80
$dgv.Columns["Status"].Width = 100

$parts = @(
    @("KELECRES-1006483A0", "Resistor 10K 0805",         "500",  "250", "Partial")
    @("CON-87137-R",        "Connector rev E",            "1000", "1000","Complete")
    @("CAP-22UF-X7R-0603",  "Capacitor 22uF X7R",        "2000", "0",   "Pending")
    @("IC-STM32F407VGT6",   "MCU ARM Cortex-M4 168MHz",  "100",  "100", "Complete")
    @("DIODE-SS34-SMB",     "Schottky diode 3A 40V",     "800",  "800", "Complete")
    @("TRANS-SN74LVC1T45",  "Voltage translator 1-bit",  "3000", "1500","Partial")
    @("LED-OSRAM-LW5SM",    "White LED 0.5W",            "5000", "5000","Complete")
    @("RELAY-G5V-1-DC5",    "Signal relay 5V SPDT",      "200",  "0",   "Pending")
    @("FUSE-0603-500MA",    "SMD fuse 500mA",            "1000", "1000","Complete")
    @("XTAL-16MHZ-20PPM",   "Crystal 16MHz 20ppm",       "400",  "400", "Complete")
    @("IND-4R7UH-1210",     "Inductor 4.7uH 1210",      "600",  "300", "Partial")
    @("CONN-USB-C-16P",     "USB-C connector 16-pin",    "250",  "250", "Complete")
    @("REG-LM1117-3V3",     "LDO regulator 3.3V 800mA",  "150",  "0",   "Pending")
    @("RES-0R-0402",        "Jumper resistor 0 ohm",     "10000","10000","Complete")
    @("MOSFET-SI2301-SOT23","P-ch MOSFET -20V -2.8A",   "500",  "250", "Partial")
    @("TVS-SMBJ5V0A",       "TVS diode 5V unidirect",   "300",  "300", "Complete")
    @("FERRITE-BLM18-100",  "Ferrite bead 10ohm 0603",  "4000", "2000","Partial")
    @("EEPROM-AT24C256",    "EEPROM 256Kbit I2C",       "100",  "100", "Complete")
    @("OPAMP-MCP6001-SOT",  "Op-amp CMOS rail-to-rail", "200",  "0",   "Pending")
    @("HEADER-2X10-2MM",    "Pin header 2x10 2mm pitch","350",  "350", "Complete")
    @("KELECRES-2007891B0", "Resistor 4K7 0603",        "1500", "750", "Partial")
    @("CAP-100NF-0402",     "Capacitor 100nF 0402",     "20000","20000","Complete")
    @("IC-ESP32-WROOM-32E", "WiFi+BT module ESP32",     "50",   "25",  "Partial")
    @("CONN-JST-PH-4P",     "JST PH connector 4-pin",  "800",  "0",   "Pending")
    @("SENSOR-BME280",      "Temp/humidity/pressure",    "75",   "75",  "Complete")
)

foreach ($p in $parts) {
    $null = $dgv.Rows.Add($p[0], $p[1], $p[2], $p[3], $p[4])
}

$form.Controls.Add($dgv)

Write-Host ""
Write-Host "Test grid is running. Search it from IMR-Part-Search.bat." -ForegroundColor Green
Write-Host "Window title contains 'Incoming' so the tool finds it automatically." -ForegroundColor Green
Write-Host ""

[System.Windows.Forms.Application]::Run($form)
