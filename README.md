# Windows Configuration Tool

A menu-driven PowerShell administration script for Windows 10/11 and Windows Server 2016+ workstations and servers. Current version: **V06** (`WIN-Setup-V06.ps1`).

## Features

- **NIC inventory** — list all adapters (real and ghosted "Not Present" devices) with link status, static/DHCP state, and APIPA (169.254.x.x) detection
- **NIC details** — per-adapter IP/gateway/DNS view plus a per-NIC internet reachability test
- **IP configuration** — set static IP/subnet mask/gateway/DNS or switch back to DHCP, per adapter
- **DNS-only changes** — update DNS servers without touching the IP address
- **Internet re-test** — quick connectivity check
- **Computer rename** — NetBIOS-validated rename with optional immediate reboot
- **Windows updates** — check/install via the Windows Update COM API (`Microsoft.Update.Session`), no external modules
- **Chocolatey menu** — ensure Chocolatey is installed, install its GUI, and one-key installs of 7-Zip, Notepad++, WinSCP, PuTTY, Brave (or ALL)
- **Domain join / leave** — join an AD domain (FQDN + credentials + optional OU path) or return to a workgroup, with friendly error mapping (e.g. domain-not-found → fix DNS first)
- **Session logging** — timestamped log file next to the script (falls back to `%TEMP%`), showing the previous session's last run and action at startup
- **Action summaries** — every completed action ends with a "WHAT THE SCRIPT DID" panel before returning to the menu

## Requirements

- Windows PowerShell 5.1 (built into Windows) or PowerShell 7+
- Run as Administrator (`#Requires -RunAsAdministrator`)
- All cmdlets used are in-box since Windows 8 / Server 2012 — no module installs needed

## Usage

```powershell
# Execution policy is AllSigned (GPO)? Use one of:
powershell.exe -ExecutionPolicy Bypass -File .\WIN-Setup-V06.ps1
# or
Set-ExecutionPolicy -Scope Process Bypass
Unblock-File .\WIN-Setup-V06.ps1

# Optional: check for a newer version at startup
powershell.exe -ExecutionPolicy Bypass -File .\WIN-Setup-V06.ps1 -CheckUpdates
```

## Notes

- Ghosted adapters (`Status: Not Present`) are never queried via CIM, avoiding the "No MSFT_NetIPInterface objects found" terminating errors those devices trigger.
- The menu keeps the screen stable: empty or invalid input shows a hint without clearing the screen; a full redraw only happens after a completed action.
