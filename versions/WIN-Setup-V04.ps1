<#
.SYNOPSIS
    Windows Configuration Tool - NIC / system management menu.

.DESCRIPTION
    Works on Windows 10 and 11 clients and Windows Server 2016 and later
    (all built-in cmdlets used here ship with Windows 8 / Server 2012 or
    newer, and the OS display adapts to every Windows 10/11 and Server
    release). An older OS is detected and warned about at startup.

    - Detects whether each NIC is using a static IP or DHCP (dynamic IP).
    - Detects APIPA / "default" autoconfiguration addresses (169.254.x.x),
      which normally mean the NIC has no DHCP server and no network connection.
    - Tests internet connectivity and reports the result.
    - Lets you change NIC settings: static IP / subnet / gateway, switch to
      DHCP, and set or clear DNS servers.
    - Rename the computer, join/leave a domain, check for Windows updates,
      install Chocolatey + its GUI.
    - Every completed action is reported on screen (press Enter to clear)
      and written to a timestamped log file next to this script, so anyone
      can see what the tool did and when it last ran.

    Startup update check is opt-in:  .\WIN-Setup-V01.ps1 -CheckUpdates
    (without the switch no update check runs at startup; menu option 7
    still lets you check for updates manually).

.VERSION
    Script name carries the version: WIN-Setup-V01.ps1. Whenever the script
    is changed, rename it with the next number (V02, V03, ...) so a server
    always shows which revision it is running. The version is displayed in
    the startup header, in every action summary, and in each log entry.

.NOTES
    Run in an elevated PowerShell session (Run as Administrator).
    All changes are applied only after you confirm each prompt.
#>

#Requires -RunAsAdministrator

param(
    # When set, the startup banner also checks for pending Windows updates.
    # Without it, no update check runs at startup (menu option 7 still works).
    [switch]$CheckUpdates
)

$ErrorActionPreference = 'Stop'

# Script version - keep in sync with the file name (WIN-Setup-V01.ps1).
# Bump this (and the file name) after every requested change.
$script:Version = 'V04'

# ----------------------------------------------------------------------------
# Logging - unique, timestamped log file next to the script
# ----------------------------------------------------------------------------

$script:LastAction = '(none yet this session)'

function Write-Log {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:LogPath `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) `
            -ErrorAction Stop
    } catch { }   # logging must never crash the tool
}

function Write-ActionLog {
    param([string]$Message)
    $script:LastAction = $Message
    Write-Log "[ACTION] $Message"
}

function Initialize-Log {
    # $PSScriptRoot (not $MyInvocation) must be used here: inside a function
    # $MyInvocation.MyCommand refers to the function itself, which would put
    # the log in the caller's working directory instead of next to the script.
    $dir = $PSScriptRoot
    if (-not $dir) { $dir = (Get-Location).Path }

    $script:LogPath = Join-Path $dir ("Set-NICConfig_{0}.log" -f `
        (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        Write-Log "SESSION START | $script:Version | user: $env:USERDOMAIN\$env:USERNAME | computer: $env:COMPUTERNAME"
        $script:LogOk = $true
    } catch {
        # Script folder may be read-only (e.g. run from a network share)
        $script:LogPath = Join-Path $env:TEMP ("Set-NICConfig_{0}.log" -f `
            (Get-Date -Format 'yyyyMMdd_HHmmss'))
        try {
            Write-Log "SESSION START | $script:Version | user: $env:USERDOMAIN\$env:USERNAME | computer: $env:COMPUTERNAME"
            $script:LogOk = $true
        } catch { $script:LogOk = $false }
        if ($script:LogOk) {
            Write-Host "  [!] Script folder is read-only - logging to $script:LogPath instead." -ForegroundColor DarkYellow
        }
    }
    $script:LogDir = $dir
}

function Get-LastRunInfo {
    <# Reads the previous session's log (newest one that is not ours). #>
    try {
        $prev = Get-ChildItem -Path $script:LogDir -Filter 'Set-NICConfig_*.log' `
            -ErrorAction Stop | Where-Object { $_.FullName -ne $script:LogPath } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $prev) { return $null }

        $lines = @(Get-Content -LiteralPath $prev.FullName -ErrorAction Stop)
        $started = $null
        foreach ($l in $lines) {
            if ($l -match '^(.+?)  SESSION START') { $started = $Matches[1]; break }
        }
        $lastAction = $null
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '\[ACTION\]\s*(.+)$') { $lastAction = $Matches[1]; break }
        }
        return [PSCustomObject]@{
            Started    = $started
            LastAction = $lastAction
            File       = $prev.Name
        }
    } catch { return $null }
}

# ----------------------------------------------------------------------------
# Visual helpers
# ----------------------------------------------------------------------------

function Write-Rule {
    param([string]$Char = '=', [int]$Width = 78)
    Write-Host ("  " + ($Char.ToString() * $Width))
}

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Rule
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Rule
}

function Show-ActionSummary {
    <# After every menu action: report what was done, wait for Enter,
       then the main loop clears the screen and redraws the header. #>
    param([string]$Message)

    Write-Host ""
    Write-Rule '-'
    Write-Host "  WHAT THE SCRIPT DID" -ForegroundColor White
    Write-Rule '-'
    Write-Host "  $Message"
    Write-Host "  Logged to: $(Split-Path -Leaf $script:LogPath)   ($script:Version)" -ForegroundColor DarkGray
    Write-Rule '-'
    $null = Read-Host "  Press Enter (OK) to continue"
}

function Show-Header {
    Clear-Host

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Rule '='
    Write-Host "  WINDOWS CONFIGURATION TOOL  ($script:Version)" -ForegroundColor Cyan
    Write-Rule '='
    Write-Host ("  Computer : {0,-34} User: {1}" -f $env:COMPUTERNAME, "$env:USERDOMAIN\$env:USERNAME") -ForegroundColor White
    if ($os) {
        Write-Host ("  OS       : {0} ({1})" -f $os.Caption, $os.Version)
    }
    if ($cs) {
        Write-Host ("  Domain   : {0}" -f $cs.Domain)
    }
    $inet = if ($script:HasInternet) { 'YES' } elseif ($null -ne $script:HasInternet) { 'NO' } else { 'not checked' }
    $inetColor = if ($script:HasInternet) { 'Green' } else { 'Red' }
    Write-Host -NoNewline ("  Internet : ")
    Write-Host -NoNewline $inet -ForegroundColor $inetColor
    Write-Host ("    Updates: {0}" -f $script:UpdateStatus)

    $lastRun = Get-LastRunInfo
    if ($lastRun) {
        $when = if ($lastRun.Started) { $lastRun.Started } else { '(unknown time)' }
        Write-Host ("  Last run : {0}  (log: {1})" -f $when, $lastRun.File) -ForegroundColor DarkGray
        if ($lastRun.LastAction) {
            Write-Host ("             last action: {0}" -f $lastRun.LastAction) -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Last run : (first recorded session)" -ForegroundColor DarkGray
    }
    Write-Host ("  Log      : {0}" -f $script:LogPath) -ForegroundColor DarkGray
    Write-Host ("  Last act : {0}" -f $script:LastAction) -ForegroundColor DarkGray
    Write-Rule '='
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "  MAIN MENU" -ForegroundColor White
    Write-Rule '-'
    Write-Host "   1) Show all NICs and their status"
    Write-Host "   2) Show details of one NIC (static/dynamic, APIPA check, DNS)"
    Write-Host "   3) Change a NIC's IP configuration (static or DHCP)"
    Write-Host "   4) Change DNS settings on a NIC"
    Write-Host "   5) Re-test internet connectivity"
    Write-Host "   6) Rename this computer"
    Write-Host "   7) Check for Windows updates (requires internet)"
    Write-Host "   8) Chocolatey: package manager, GUI, and common applications"
    Write-Host "   9) Join an Active Directory domain (prompts for domain + credentials)"
    Write-Host "  10) Leave the domain (join a workgroup)"
    Write-Host "   0) Exit"
    Write-Rule '-'
}

# ----------------------------------------------------------------------------
# System info / compatibility
# ----------------------------------------------------------------------------

function Get-SystemSummary {
    <# Returns host name + Windows version/build info. #>
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Name           = $env:COMPUTERNAME
        DisplayVersion = if ($cv.DisplayVersion) { $cv.DisplayVersion } elseif ($cv.ReleaseId) { $cv.ReleaseId } else { '?' }
        Build          = "$($cv.CurrentBuildNumber).$($cv.UBR)"
    }
}

function Test-Compatibility {
    <# The network cmdlets used require Windows 8 / Server 2012 or later.
       Warn (but do not block) when running on anything older. #>
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -ErrorAction SilentlyContinue).CurrentBuildNumber
    if ($build -lt 9200) {
        Write-Host "  [!] WARNING: This OS build ($build) predates Windows 8 / Server 2012." -ForegroundColor Red
        Write-Host "      Some NIC cmdlets used by this tool do not exist on it." -ForegroundColor Red
        return $false
    }
    return $true
}

# ----------------------------------------------------------------------------
# Connectivity checks
# ----------------------------------------------------------------------------

function Test-InternetConnectivity {
    <# Returns $true when the machine can reach the internet. #>
    try {
        # DNS + HTTP check against a well-known endpoint (fast, 2s timeout)
        $resp = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' `
            -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Test-NicInternet {
    param([string]$AdapterName)
    try {
        $nic = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        # Find-NetRoute shows which interface/source IP Windows would actually
        # use to reach an internet address - no route = no internet.
        $selected = Find-NetRoute -RemoteIPAddress '8.8.8.8' -ErrorAction Stop |
            Select-Object -First 1
        return ($null -ne $selected -and $selected.InterfaceIndex -eq $nic.ifIndex)
    } catch {
        return $false
    }
}

# ----------------------------------------------------------------------------
# NIC reporting and selection
# ----------------------------------------------------------------------------

function Get-NicReport {
    <# Builds a status object for one adapter's IPv4 configuration. #>
    param([Parameter(Mandatory = $true)]$Adapter)

    $ipConfig = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex `
        -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Sort-Object -Property PrefixOrigin |
        Select-Object -First 1

    $gateway = (Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex `
        -ErrorAction SilentlyContinue).IPv4DefaultGateway.NextHop

    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex `
        -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

    $isApipa = $false
    if ($ipConfig -and $ipConfig.IPAddress -like '169.254.*') { $isApipa = $true }

    $source = switch ($ipConfig.PrefixOrigin) {
        'Dhcp'    { 'Dynamic (DHCP)' }
        'Manual'  { 'Static (Manual)' }
        default   { 'Unknown / not configured' }
    }

    # "Not Present" / fully removed adapters have no IPv4 interface stack.
    # Do NOT query per-adapter with -InterfaceIndex here: that query is the
    # one CimCmdlets raises as a terminating "No MSFT_NetIPInterface objects
    # found" error that -ErrorAction cannot suppress. Fetch the whole IPv4
    # interface table once (always succeeds) and match locally instead.
    $dhcpEnabled = $false
    try {
        $dhcpEnabled = ((Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object InterfaceIndex -EQ $Adapter.ifIndex |
            Select-Object -First 1).Dhcp -eq 'Enabled')
    } catch { $dhcpEnabled = $false }

    [PSCustomObject]@{
        Name        = $Adapter.Name
        ifIndex     = $Adapter.ifIndex
        Status      = $Adapter.Status
        LinkSpeed   = $Adapter.LinkSpeed
        MacAddress  = $Adapter.MacAddress
        IPSource    = $source
        # Computed above: try/catch is not valid inside a hashtable literal.
        DhcpEnabled = $dhcpEnabled
        IPAddress   = if ($ipConfig) { $ipConfig.IPAddress } else { '(none)' }
        PrefixLen   = if ($ipConfig) { $ipConfig.PrefixLength } else { '-' }
        Gateway     = if ($gateway) { $gateway } else { '(none)' }
        DNS         = if ($dnsServers) { $dnsServers -join ', ' } else { '(none)' }
        IsApipa     = $isApipa
    }
}

function Show-NicDetail {
    param([Parameter(Mandatory = $true)]$Report)

    Write-Host ""
    Write-Host "  NIC:        $($Report.Name)  (ifIndex $($Report.ifIndex))" -ForegroundColor White
    Write-Host "  Status:     $($Report.Status)   Link: $($Report.LinkSpeed)   MAC: $($Report.MacAddress)"
    Write-Host "  IP source:  $($Report.IPSource)" -ForegroundColor $(if ($Report.DhcpEnabled) { 'Yellow' } else { 'Green' })
    Write-Host "  IPv4:       $($Report.IPAddress)/$($Report.PrefixLen)"
    Write-Host "  Gateway:    $($Report.Gateway)"
    Write-Host "  DNS:        $($Report.DNS)"

    if ($Report.IsApipa) {
        Write-Host ""
        Write-Host "  [!] WARNING: This NIC is using an APIPA self-assigned address" -ForegroundColor Red
        Write-Host "      (169.254.x.x = the DEFAULT IP Windows uses when no DHCP server" -ForegroundColor Red
        Write-Host "      answers and no static address is set). The server very likely" -ForegroundColor Red
        Write-Host "      has NO working network connection on this NIC." -ForegroundColor Red
    }
}

function Show-NicList {
    # @() forces a true array even when only ONE adapter exists - PowerShell
    # otherwise unwraps a single-item result to a scalar, on which .Count and
    # indexing behave inconsistently in Windows PowerShell 5.1.
    $adapters = @(Get-NetAdapter | Sort-Object Name)
    $i = 0
    foreach ($a in $adapters) {
        $i++
        $r = Get-NicReport -Adapter $a
        $flag = ''
        if ($r.Status -eq 'Not Present') { $flag = '  <-- not present (ghost adapter)' }
        elseif ($r.IsApipa) { $flag = '  <-- APIPA/default IP, no network' }
        elseif ($r.Status -ne 'Up') { $flag = '  <-- disconnected' }
        Write-Host ("  [{0}] {1,-25} {2,-12} {3,-22} {4}" -f `
            $i, $r.Name, $r.Status, $r.IPAddress, ($r.IPSource + $flag))
    }
    return $adapters
}

function Select-Nic {
    <# Prompts until a valid adapter is chosen. Returns the adapter object. #>
    param([Parameter(Mandatory = $true)]$Adapters)

    # Normalize to a real array so .Count and indexing are always correct,
    # even when a single adapter was passed in (scalar on PS 5.1).
    $Adapters = @($Adapters)

    while ($true) {
        $choice = Read-Host "Select a NIC by number (or press Enter to cancel)"
        if ([string]::IsNullOrWhiteSpace($choice)) { return $null }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $Adapters.Count) {
            return $Adapters[$idx - 1]
        }
        Write-Host "Invalid selection, try again." -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------------------
# NIC changes
# ----------------------------------------------------------------------------

function Set-StaticIp {
    param([Parameter(Mandatory = $true)]$Adapter)

    Write-Title "Set STATIC IPv4 configuration on '$($Adapter.Name)'"

    $ip = Read-Host "New static IPv4 address (e.g. 192.168.1.50)"
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Host "Invalid IP format, aborting change." -ForegroundColor Red
        return
    }

    $pl = Read-Host "Subnet prefix length (e.g. 24 for a /24 = 255.255.255.0)"
    $gw = Read-Host "Default gateway (leave blank if none)"
    $dns = Read-Host "DNS servers, comma-separated (blank keeps current DNS, 'reset' = DHCP-provided DNS)"

    Write-Host ""
    Write-Host "  You are about to set on '$($Adapter.Name)':" -ForegroundColor Yellow
    Write-Host "    IP:      $ip /$pl"
    Write-Host "    Gateway: $(if ($gw) { $gw } else { '(none)' })"
    Write-Host "    DNS:     $(if ($dns) { $dns } else { '(keep current)' })"
    $confirm = Read-Host "Apply these settings? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Yellow
        return
    }

    try {
        if ($gw) {
            New-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $ip `
                -PrefixLength ([int]$pl) -DefaultGateway $gw -ErrorAction Stop | Out-Null
        } else {
            New-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $ip `
                -PrefixLength ([int]$pl) -ErrorAction Stop | Out-Null
        }

        if ($dns -eq 'reset') {
            Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
        } elseif ($dns) {
            $dnsList = @($dns -split '\s*,\s*' | Where-Object { $_ })
            Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $dnsList
        }
        Write-Host "Static configuration applied." -ForegroundColor Green
        Write-ActionLog "Set STATIC IPv4 on '$($Adapter.Name)': IP $ip/$pl, gateway $(if ($gw) { $gw } else { 'none' }), DNS $(if ($dns) { $dns } else { 'unchanged' })"
    } catch {
        Write-Host "ERROR applying settings: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] static IP on '$($Adapter.Name)': $($_.Exception.Message)"
        Write-Host "(If the IP already exists, remove it first: Remove-NetIPAddress -InterfaceIndex $($Adapter.ifIndex) -IPAddress <old-ip>)" -ForegroundColor DarkYellow
    }
}

function Set-DhcpMode {
    param([Parameter(Mandatory = $true)]$Adapter)

    Write-Title "Switch '$($Adapter.Name)' to DYNAMIC (DHCP)"
    $confirm = Read-Host "Switch this NIC to DHCP? Existing static IP/DNS will be removed. (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Yellow
        return
    }
    try {
        # Remove manual IPv4 settings so DHCP can take over cleanly
        Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 |
            Where-Object { $_.PrefixOrigin -eq 'Manual' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix '0.0.0.0/0' |
            Where-Object { $_.Protocol -eq 'Static' } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        Set-NetIPInterface -InterfaceIndex $Adapter.ifIndex -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses

        Write-Host "DHCP enabled - renewing address..." -ForegroundColor Green
        $Adapter2 = Get-NetAdapter -InterfaceIndex $Adapter.ifIndex
        if ($Adapter2.Status -eq 'Up') {
            ipconfig /renew | Out-Null
        }
        $newIp = (Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        Write-ActionLog "Switched '$($Adapter.Name)' to DHCP (renewed address: $newIp)"
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] DHCP switch on '$($Adapter.Name)': $($_.Exception.Message)"
    }
}

function Set-DnsOnly {
    param([Parameter(Mandatory = $true)]$Adapter)

    Write-Title "Change DNS servers on '$($Adapter.Name)'"
    Write-Host "  Current DNS: $((Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ', ')"
    Write-Host ""
    Write-Host "  1) Set specific DNS servers"
    Write-Host "  2) Reset to DHCP-provided / default DNS"
    $mode = Read-Host "Choose (1/2)"

    if ($mode -eq '1') {
        $dns = Read-Host "DNS servers, comma-separated (e.g. 192.168.1.1,8.8.8.8)"
        $dnsList = @($dns -split '\s*,\s*' | Where-Object { $_ })
        if (-not $dnsList -or $dnsList.Count -eq 0) {
            Write-Host "No DNS entered, cancelled." -ForegroundColor Yellow
            return
        }
        $confirm = Read-Host "Set DNS to $($dnsList -join ', ')? (Y/N)"
        if ($confirm -match '^[Yy]') {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $dnsList -ErrorAction Stop
                Write-Host "DNS updated." -ForegroundColor Green
                Write-ActionLog "Set DNS on '$($Adapter.Name)' to $($dnsList -join ', ')"
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "[ERROR] DNS on '$($Adapter.Name)': $($_.Exception.Message)"
            }
        }
    } elseif ($mode -eq '2') {
        $confirm = Read-Host "Reset DNS to DHCP/default? (Y/N)"
        if ($confirm -match '^[Yy]') {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
                Write-Host "DNS reset." -ForegroundColor Green
                Write-ActionLog "Reset DNS on '$($Adapter.Name)' to DHCP/default"
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "[ERROR] DNS reset on '$($Adapter.Name)': $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "Cancelled." -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------------------
# Updates
# ----------------------------------------------------------------------------

function Show-PendingUpdatesSummary {
    <# Startup-banner summary: counts pending Windows updates without prompting
       or installing anything. The full interactive check lives in menu 7. #>
    Write-Host "Windows updates:  checking..."
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
        $n = $result.Updates.Count
        if ($n -eq 0) {
            Write-Host "Windows updates:  none pending (system up to date)" -ForegroundColor Green
        } else {
            Write-Host "Windows updates:  $n pending - use menu option 7 to review and install" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Windows updates:  could not check ($($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Check-WindowsUpdates {
    Write-Title "Windows Update check"
    if (-not (Test-InternetConnectivity)) {
        Write-Host "No internet access - cannot check for updates." -ForegroundColor Red
        return
    }
    Write-Host "Searching Windows Update (this can take a minute)..."
    try {
        # Built-in Windows Update COM API - no modules needed
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")

        if ($result.Updates.Count -eq 0) {
            Write-Host "System is up to date - no pending updates." -ForegroundColor Green
            Write-ActionLog "Checked Windows updates: none pending"
            return
        }

        Write-Host ("Found {0} pending update(s):" -f $result.Updates.Count) -ForegroundColor Yellow
        $i = 0
        foreach ($u in $result.Updates) {
            $i++
            $sizeMb = [math]::Round($u.MaxDownloadSize / 1MB, 1)
            Write-Host ("  [{0}] {1}  ({2} MB)" -f $i, $u.Title, $sizeMb)
        }

        $install = Read-Host "Download and install ALL of these now? (Y/N)"
        if ($install -notmatch '^[Yy]') {
            Write-Host "Cancelled - nothing downloaded." -ForegroundColor Yellow
            Write-ActionLog ("Checked Windows updates: {0} pending listed, install declined" -f $result.Updates.Count)
            return
        }

        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $result.Updates) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            $null = $coll.Add($u)
        }

        Write-Host "Downloading..."
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $coll
        $downloader.Download() | Out-Null

        Write-Host "Installing... (this may take a while)"
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $coll
        $res = $installer.Install()

        if ($res.ResultCode -eq 2) {
            Write-Host "Updates installed successfully." -ForegroundColor Green
        } elseif ($res.ResultCode -eq 3) {
            Write-Host "Updates installed with errors - a reboot is likely required." -ForegroundColor Yellow
        } else {
            Write-Host "Install FAILED (result code $($res.ResultCode))." -ForegroundColor Red
        }
        if ($res.RebootRequired) {
            Write-Host "A REBOOT is required to finish the updates." -ForegroundColor Yellow
        }
        Write-ActionLog ("Installed {0} Windows update(s); result code {1}; reboot required: {2}" -f `
            $result.Updates.Count, $res.ResultCode, [bool]$res.RebootRequired)
    } catch {
        Write-Host "ERROR checking updates: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] update check: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Rename / Chocolatey
# ----------------------------------------------------------------------------

function Rename-ThisComputer {
    Write-Title "Rename this computer"
    Write-Host "  Current name: $env:COMPUTERNAME" -ForegroundColor White
    $newName = Read-Host "New computer name (blank = cancel)"
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
    # NetBIOS name rules: letters, digits, hyphen; 1-15 chars; not all digits
    if ($newName -notmatch '^[a-zA-Z0-9-]{1,15}$' -or $newName -match '^\d+$') {
        Write-Host "Invalid name: use letters/digits/hyphen, max 15 characters, not all digits." -ForegroundColor Red
        return
    }
    if ($newName -eq $env:COMPUTERNAME) {
        Write-Host "Name is unchanged." -ForegroundColor Yellow
        return
    }
    $confirm = Read-Host "Rename '$env:COMPUTERNAME' to '$newName'? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Yellow
        return
    }
    try {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        Write-Host "Rename applied. A REBOOT is required for it to take effect." -ForegroundColor Green
        Write-ActionLog "Renamed computer: '$env:COMPUTERNAME' -> '$newName' (reboot pending)"
        $reboot = Read-Host "Restart now? (Y/N)"
        if ($reboot -match '^[Yy]') {
            Write-Log "[ACTION] Restarting computer at user request"
            Restart-Computer -Force
        } else {
            Write-Host "Reboot later to activate the new name."
        }
    } catch {
        Write-Host "ERROR renaming: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] rename: $($_.Exception.Message)"
    }
}

function Ensure-Chocolatey {
    <# Makes sure the choco CLI is present. Returns $true when ready to use. #>
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  Chocolatey is already installed: $((Get-Command choco).Version)" -ForegroundColor Green
        return $true
    }
    if (-not (Test-InternetConnectivity)) {
        Write-Host "  No internet access - cannot install Chocolatey." -ForegroundColor Red
        return $false
    }
    $confirm = Read-Host "  Install Chocolatey from https://chocolatey.org/install.ps1? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        return $false
    }
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        # Refresh PATH in this session so 'choco' is usable immediately
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "  Chocolatey installed." -ForegroundColor Green
            Write-ActionLog "Installed Chocolatey package manager"
            return $true
        }
        Write-Host "  Chocolatey install ran but 'choco' is still not on PATH - restart PowerShell." -ForegroundColor Red
        return $false
    } catch {
        Write-Host "  ERROR installing Chocolatey: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] Chocolatey install: $($_.Exception.Message)"
        return $false
    }
}

function Get-ChocoInstalled {
    param([string]$PackageId)
    $out = & choco list --exact $PackageId --limit-output 2>$null
    return [bool]($out | Where-Object { $_ -match "^\s*$([regex]::Escape($PackageId))\|" })
}

function Start-ChocolateyGui {
    <# Starts the GUI; installs it first when missing. #>
    if (-not (Ensure-Chocolatey)) { return }

    Write-Host "  Locating Chocolatey GUI..."
    # Search only where the GUI actually lives; both dirs exist on Windows
    $guiDirs = @("${env:ProgramFiles(x86)}\Chocolatey GUI", "$env:ProgramFiles\Chocolatey GUI") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $guiExe = if ($guiDirs) {
        @(Get-ChildItem $guiDirs -Filter 'ChocolateyGui.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1)
    } else { @() }

    if (-not $guiExe -and $guiDirs -and (Get-ChocoInstalled -PackageId 'chocolateygui')) {
        # Listed in choco but exe not found - search once more
        $guiExe = @(Get-ChildItem $guiDirs -Filter 'ChocolateyGui.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1)
    }

    if ($guiExe) {
        Write-Host "  Starting Chocolatey GUI..." -ForegroundColor Green
        Start-Process -FilePath $guiExe[0].FullName
        Write-ActionLog "Started Chocolatey GUI ($($guiExe[0].FullName))"
        return
    }

    if (-not (Test-InternetConnectivity)) {
        Write-Host "  No internet access - cannot install the GUI." -ForegroundColor Red
        return
    }
    $confirm = Read-Host "  Chocolatey GUI is not installed. Install it now? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "  Cancelled. Install later with: choco install chocolateygui -y" -ForegroundColor Yellow
        Write-ActionLog "Chocolatey GUI start requested; GUI not installed - install declined"
        return
    }
    try {
        & choco install chocolateygui -y
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  choco exited with code $LASTEXITCODE - check output above." -ForegroundColor Red
            Write-Log "[ERROR] Chocolatey GUI install: choco exit code $LASTEXITCODE"
            return
        }
        Write-Host "  Chocolatey GUI installed." -ForegroundColor Green
        Write-ActionLog "Installed Chocolatey GUI (choco install chocolateygui)"
        $guiExe = if ($guiDirs) {
            @(Get-ChildItem $guiDirs -Filter 'ChocolateyGui.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1)
        } else { @() }
        if ($guiExe) {
            Start-Process -FilePath $guiExe[0].FullName
            Write-Host "  Chocolatey GUI started." -ForegroundColor Green
            Write-ActionLog "Started Chocolatey GUI (after install)"
        } else {
            Write-Host "  Installed, but could not locate ChocolateyGui.exe - launch it from the Start menu." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] Chocolatey GUI install/start: $($_.Exception.Message)"
    }
}

$script:CommonApps = @(
    @{ Display = '7-Zip';          Id = '7zip' },
    @{ Display = 'Notepad++';      Id = 'notepadplusplus' },
    @{ Display = 'WinSCP';         Id = 'winscp' },
    @{ Display = 'PuTTY';          Id = 'putty' },
    @{ Display = 'Brave Browser';  Id = 'brave' }
)

function Install-ChocoApp {
    param([hashtable]$App)

    if (-not (Ensure-Chocolatey)) { return }
    if (-not (Test-InternetConnectivity)) {
        Write-Host "  No internet access - cannot install $($App.Display)." -ForegroundColor Red
        return
    }

    if (Get-ChocoInstalled -PackageId $App.Id) {
        Write-Host "  $($App.Display) is already installed." -ForegroundColor Green
        Write-ActionLog "$($App.Display) already installed (choco package $($App.Id))"
        return
    }

    $confirm = Read-Host "  Install $($App.Display) (choco package '$($App.Id)')? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        return
    }
    try {
        & choco install $App.Id -y
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $($App.Display) installed." -ForegroundColor Green
            Write-ActionLog "Installed $($App.Display) (choco install $($App.Id))"
        } else {
            Write-Host "  choco exited with code $LASTEXITCODE - check output above." -ForegroundColor Red
            Write-Log "[ERROR] $($App.Display) install: choco exit code $LASTEXITCODE"
        }
    } catch {
        Write-Host "  ERROR installing $($App.Display): $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] $($App.Display) install: $($_.Exception.Message)"
    }
}

function Show-ChocolateyMenu {
    while ($true) {
        Write-Title "Chocolatey sub-menu"
        Write-Host "   1) Ensure Chocolatey package manager is installed"
        Write-Host "   2) Start Chocolatey GUI (installs it first if missing)"
        $n = 3
        foreach ($app in $script:CommonApps) {
            Write-Host ("   {0}) Install {1}" -f $n, $app.Display)
            $n++
        }
        Write-Host ("   {0}) Install ALL of the applications above" -f $n)
        Write-Host "   0) Back to main menu"
        Write-Rule '-'

        $choice = Read-Host "  Choose an option"
        if ($null -eq $choice) { return }   # input stream closed - leave sub-menu
        $maxApp = $script:CommonApps.Count

        if ($choice -eq '0') { return }
        elseif ($choice -eq '1') {
            $wasInstalled = [bool](Get-Command choco -ErrorAction SilentlyContinue)
            if (Ensure-Chocolatey) {
                Show-ActionSummary $(if ($wasInstalled) { "Checked Chocolatey: already installed, nothing changed." } else { $script:LastAction })
            }
            continue
        }
        elseif ($choice -eq '2') {
            Start-ChocolateyGui
            Show-ActionSummary $script:LastAction
            continue
        }
        elseif ($choice -eq 'all' -or $choice -eq [string]($maxApp + 3)) {
            foreach ($app in $script:CommonApps) { Install-ChocoApp -App $app }
            Show-ActionSummary $script:LastAction
            continue
        }
        elseif ([int]::TryParse($choice, [ref]$null) -and $choice -ge 3 -and $choice -le ($maxApp + 2)) {
            Install-ChocoApp -App $script:CommonApps[[int]$choice - 3]
            Show-ActionSummary $script:LastAction
            continue
        }
        else {
            Write-Host "  Unknown option." -ForegroundColor Yellow
        }
    }
}

# ----------------------------------------------------------------------------
# Domain join / leave
# ----------------------------------------------------------------------------

function Join-DomainInteractive {
    Write-Title "Join this computer to an Active Directory domain"
    Write-Host "  Current domain/workgroup: $((Get-CimInstance Win32_ComputerSystem).Domain)" -ForegroundColor White

    $domain = Read-Host "Domain name (FQDN, e.g. corp.example.com - blank = cancel)"
    if ([string]::IsNullOrWhiteSpace($domain)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    # Sanity-check the FQDN before asking for credentials
    if ($domain -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$') {
        Write-Host "That does not look like a valid FQDN (e.g. corp.example.com)." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "  Enter DOMAIN credentials (a domain account with rights to add" -ForegroundColor White
    Write-Host "  computers, or a delegated account). Format: DOMAIN\username" -ForegroundColor White
    $cred = Get-Credential -UserName "$($env:USERDOMAIN)\administrator" `
        -Message "Account authorized to join $domain"
    if (-not $cred) {
        Write-Host "Cancelled - no credentials entered." -ForegroundColor Yellow
        return
    }

    $ou = Read-Host "Target OU (distinguished name, blank = default Computers container)"
    Write-Host ""
    Write-Host "  You are about to join domain '$domain'" -ForegroundColor Yellow
    Write-Host "    as user:   $($cred.UserName)"
    Write-Host "    into OU:   $(if ($ou) { $ou } else { '(default Computers container)' })"
    Write-Host "    restart:   required after joining (you will be asked)"
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Yellow
        return
    }

    try {
        if ($ou) {
            Add-Computer -DomainName $domain -Credential $cred -OUPath $ou -Force -ErrorAction Stop
        } else {
            Add-Computer -DomainName $domain -Credential $cred -Force -ErrorAction Stop
        }
        Write-Host "Joined '$domain' successfully. A REBOOT is required to apply it." -ForegroundColor Green
        Write-ActionLog "Joined domain '$domain' (as $($cred.UserName), OU: $(if ($ou) { $ou } else { 'default' }); reboot pending)"
        $reboot = Read-Host "Restart now? (Y/N)"
        if ($reboot -match '^[Yy]') {
            # Keep the join details visible: the reboot line carries them, so
            # the next session's header "last action" still shows domain+user.
            Write-Log "[ACTION] Restarting computer at user request (after: joined domain '$domain' as $($cred.UserName))"
            Restart-Computer -Force
        } else {
            Write-Host "Reboot later to complete the domain join."
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Cannot find|not found') {
            Write-Host "ERROR: domain '$domain' could not be found. Check DNS on this NIC" -ForegroundColor Red
            Write-Host "(the NIC's DNS must point at a domain controller or resolvable DNS for $domain)." -ForegroundColor Red
            Write-Host "Use menu option 4 to set DNS first, then retry." -ForegroundColor Yellow
        } elseif ($msg -match 'access is denied|denied|logon failure') {
            Write-Host "ERROR: the supplied credentials were rejected (access denied or logon failure)." -ForegroundColor Red
        } else {
            Write-Host "ERROR joining domain: $msg" -ForegroundColor Red
        }
        Write-Log "[ERROR] domain join '$domain': $msg"
    }
}

function Join-WorkgroupInteractive {
    Write-Title "Leave the domain (join a workgroup)"
    Write-Host "  Current domain/workgroup: $((Get-CimInstance Win32_ComputerSystem).Domain)" -ForegroundColor White
    $wg = Read-Host "Workgroup name (blank = cancel, default WORKGROUP)"
    if ([string]::IsNullOrWhiteSpace($wg)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    $cred = Get-Credential -Message "Domain admin credentials (needed to leave a domain)"
    if (-not $cred) { Write-Host "Cancelled - no credentials entered." -ForegroundColor Yellow; return }
    try {
        Add-Computer -WorkGroupName $wg -Credential $cred -Force -ErrorAction Stop
        Write-Host "Moved to workgroup '$wg'. A REBOOT is required." -ForegroundColor Green
        Write-ActionLog "Left domain, joined workgroup '$wg' (reboot pending)"
        $reboot = Read-Host "Restart now? (Y/N)"
        if ($reboot -match '^[Yy]') {
            Write-Log "[ACTION] Restarting computer at user request"
            Restart-Computer -Force
        }
    } catch {
        Write-Host "ERROR leaving domain: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] leave domain: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

Initialize-Log

$compat = Test-Compatibility
$hasInternet = Test-InternetConnectivity
$script:HasInternet = $hasInternet
$script:UpdateStatus = 'not checked (menu 7)'

if ($hasInternet -and $CheckUpdates) {
    # Opt-in startup check (no installs, count only)
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
        $n = $result.Updates.Count
        if ($n -eq 0) {
            $script:UpdateStatus = 'none pending'
        } else {
            $script:UpdateStatus = "$n pending (menu 7 to review)"
        }
    } catch {
        $script:UpdateStatus = 'check failed'
    }
}

    Write-Log ("$script:Version | OS: {0} ({1}) | internet: {2} | compatibility: {3}" -f `
    (Get-CimInstance Win32_OperatingSystem).Caption, $PSVersionTable.PSVersion.ToString(),
    $(if ($hasInternet) { 'YES' } else { 'NO' }), $(if ($compat) { 'ok' } else { 'old OS' }))

while ($true) {
    Show-Header
    Show-MainMenu
    $menu = Read-Host "  Choose an option"
    if ($null -eq $menu) { Write-Log "SESSION END (input closed)"; return }

    switch ($menu) {
        '1' {
            Write-Title "All network adapters"
            $null = Show-NicList
            $anyApipa = @(Get-NetAdapter | ForEach-Object { Get-NicReport -Adapter $_ } |
                Where-Object { $_.IsApipa -and $_.Status -ne 'Not Present' })
            if ($anyApipa) {
                Write-Host ""
                Write-Host "  [!] One or more NICs are on APIPA/default (169.254.x.x) addresses:" -ForegroundColor Red
                Write-Host "      $($anyApipa.Name -join ', ')" -ForegroundColor Red
                Write-Host "      This means: no DHCP answer + no static IP => no network connection." -ForegroundColor Red
            }
            Write-ActionLog ("Listed {0} NIC(s); APIPA present: {1}" -f `
                @(Get-NetAdapter).Count, $(if ($anyApipa) { ($anyApipa.Name -join ', ') } else { 'no' }))
            Show-ActionSummary "Listed all NICs with static/Dynamic status$(if ($anyApipa) { ' - APIPA/default-IP warning shown' })."
        }
        '2' {
            Write-Title "NIC details"
            $adapters = @(Show-NicList)
            if (-not $adapters) { Write-Host "No network adapters found." -ForegroundColor Red; continue }
            $sel = Select-Nic -Adapters $adapters
            if ($sel) {
                Show-NicDetail -Report (Get-NicReport -Adapter $sel)
                $reachable = Test-NicInternet -AdapterName $sel.Name
                if ($reachable) {
                    Write-Host "  Internet:   reachable via this NIC" -ForegroundColor Green
                } else {
                    Write-Host "  Internet:   NOT reachable via this NIC" -ForegroundColor Red
                }
                Write-ActionLog "Showed details of NIC '$($sel.Name)' (internet reachable: $reachable)"
                Show-ActionSummary "Showed detail for '$($sel.Name)' (static/dynamic, gateway, DNS, internet test)."
            }
        }
        '3' {
            Write-Title "Change IP configuration"
            $adapters = @(Show-NicList)
            if (-not $adapters) { continue }
            $sel = Select-Nic -Adapters $adapters
            if (-not $sel) { continue }
            Show-NicDetail -Report (Get-NicReport -Adapter $sel)
            Write-Host ""
            Write-Host "  1) Set a STATIC IP / gateway / DNS"
            Write-Host "  2) Switch to DYNAMIC (DHCP)"
            Write-Host "  3) Back to main menu"
            $mode = Read-Host "Choose (1/2/3)"
            if     ($mode -eq '1') { Set-StaticIp -Adapter $sel }
            elseif ($mode -eq '2') { Set-DhcpMode -Adapter $sel }
            if ($mode -eq '1' -or $mode -eq '2') {
                Show-ActionSummary $script:LastAction
            }
        }
        '4' {
            Write-Title "Change DNS settings"
            $adapters = @(Show-NicList)
            if (-not $adapters) { continue }
            $sel = Select-Nic -Adapters $adapters
            if (-not $sel) { continue }
            Set-DnsOnly -Adapter $sel
            Show-ActionSummary $script:LastAction
        }
        '5' {
            $ok = Test-InternetConnectivity
            $script:HasInternet = $ok
            if ($ok) {
                Write-Host "Internet connectivity: YES" -ForegroundColor Green
                Write-ActionLog "Re-tested internet connectivity: YES"
                Show-ActionSummary "Re-tested internet connectivity: YES."
            } else {
                Write-Host "Internet connectivity: NO" -ForegroundColor Red
                Write-ActionLog "Re-tested internet connectivity: NO"
                Show-ActionSummary "Re-tested internet connectivity: NO."
            }
        }
        '6' {
            Rename-ThisComputer
            Show-ActionSummary $script:LastAction
        }
        '7' {
            Check-WindowsUpdates
            Show-ActionSummary $script:LastAction
        }
        '8' {
            Show-ChocolateyMenu
            Show-ActionSummary $script:LastAction
        }
        '9' {
            Join-DomainInteractive
            Show-ActionSummary $script:LastAction
        }
        '10' {
            Join-WorkgroupInteractive
            Show-ActionSummary $script:LastAction
        }
        '0' {
            Write-Log "SESSION END"
            return
        }
        default { Write-Host "Unknown option." -ForegroundColor Yellow }
    }
}
