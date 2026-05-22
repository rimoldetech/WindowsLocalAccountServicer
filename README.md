# Windows Local Account Manager (WLAM)

A robust PowerShell script for managing local Windows user accounts. Designed for use with [TacticalRMM](https://docs.tacticalrmm.com/) and similar RMM platforms, but equally useful interactively — run it without arguments to get a full text-based menu interface.

WLAM consolidates account creation, password management, enable/disable, Administrator promotion/demotion, lock screen visibility, and account info updates into a single script. Multiple actions can be combined in one invocation, and passwords are generated cryptographically at random when not provided.

---

## Screenshot

![TUI screenshot](screenshots/tui.png)

---

## Features

- **Interactive TUI** — menu-driven interface for use directly on a machine or in a basic remote session
- **Non-interactive / RMM mode** — fully argument-driven, no prompts, suitable for automated deployment
- **Multi-action support** — combine actions in a single run; they always execute in a safe logical order
- **Random password generation** — cryptographically secure, guarantees mixed character classes; used by default when no password is supplied
- **Lock screen management** — hide or show accounts on the Windows login screen via registry
- **Automatic registry cleanup** — deleting an account also removes any associated lock screen registry entry
- **Consistent output format** — `[OK]`, `[INFO]`, `[WARN]`, `[ERROR]` prefixes on all output for easy RMM log parsing

---

## Requirements

- Windows PowerShell 5.1 or later
- Must be run as a local Administrator
- Target machine must support the `Microsoft.PowerShell.LocalAccounts` module (included in Windows 10/11 and Server 2016+)

---

## Usage

### Interactive TUI

Run WLAM with no arguments to launch the menu interface.

```powershell
.\WLAM.ps1
```

### Non-Interactive (RMM / CLI)

```powershell
.\WLAM.ps1 -Username <string> -Action <action[,action,...]> [options]
```

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-Username` | string | For most actions | Target local account name. Not required for `List`. |
| `-Action` | string[] | Yes | One or more actions to perform (see below). Comma-separated or passed multiple times. |
| `-Password` | string | No | Plaintext password for `Create` or `ResetPassword`. Auto-generated if omitted. |
| `-PasswordLength` | int | No | Length of the auto-generated password. Default: `20`. |
| `-FullName` | string | No | Display name for the account. Used with `Create` and `SetInfo`. |
| `-Description` | string | No | Account description. Used with `Create` and `SetInfo`. |
| `-Admin` | switch | No | When used with `Create`, adds the account to the Administrators group. |

---

## Actions

| Action | Description |
|---|---|
| `List` | List all local accounts with Enabled, Admin, Hidden, and description status. |
| `Create` | Create a new local user account. |
| `Delete` | Delete an account. Also removes any associated lock screen registry entry. |
| `Enable` | Enable a disabled account. |
| `Disable` | Disable an account. |
| `ResetPassword` | Reset the account password. Generates a random password if `-Password` is not provided. |
| `SetInfo` | Update the full name and/or description of an existing account. |
| `Promote` | Add the account to the Administrators group. |
| `Demote` | Remove the account from the Administrators group. |
| `Hide` | Hide the account from the Windows lock screen. Takes effect after a restart. |
| `Show` | Show the account on the Windows lock screen. Takes effect after a restart. |

When multiple actions are specified, they always execute in this order regardless of how they are passed: `Create → Enable/Disable → ResetPassword → SetInfo → Promote/Demote → Hide/Show → Delete → List`

---

## Examples

**List all local accounts**
```powershell
.\WLAM.ps1 -Action List
```

**Create a standard user with a random password**
```powershell
.\WLAM.ps1 -Username jdoe -Action Create -FullName "John Doe"
```

**Create an admin account with a specific password**
```powershell
.\WLAM.ps1 -Username svcadmin -Action Create -Password "P@ssw0rd!" -Admin
```

**Create an admin account, hide from lock screen, and enable in one run**
```powershell
.\WLAM.ps1 -Username svcadmin -Action Create,Hide,Enable -Admin
```

**Reset a password (random) and hide from lock screen**
```powershell
.\WLAM.ps1 -Username jdoe -Action ResetPassword,Hide
```

**Promote an existing account and enable it**
```powershell
.\WLAM.ps1 -Username jdoe -Action Promote,Enable
```

**Update full name and description**
```powershell
.\WLAM.ps1 -Username jdoe -Action SetInfo -FullName "John Doe" -Description "Finance dept"
```

**Disable an account**
```powershell
.\WLAM.ps1 -Username jdoe -Action Disable
```

**Delete an account**
```powershell
.\WLAM.ps1 -Username olduser -Action Delete
```

---

## TacticalRMM Notes

This script is designed to work cleanly within TacticalRMM:

- All output uses `Write-Output` (not `Write-Host`) for reliable stdout capture in RMM logs
- Exit codes: `0` on success, `1` on error
- The `[OK]`, `[INFO]`, `[WARN]`, and `[ERROR]` output prefixes are consistent across all actions and suitable for log parsing or alert conditions
- Pass arguments directly via the script arguments field; no modification to the script is needed per-deployment

---

## Notes

- Lock screen `Hide`/`Show` changes require a **system restart** to take effect
- Deleting an account automatically removes its lock screen registry entry if one exists, preventing it from being silently inherited by a future account with the same username
- The random password generator uses `RNGCryptoServiceProvider` and guarantees at least one lowercase letter, uppercase letter, digit, and special character in every generated password

---

## Contributing

Contributions, bug reports, and feature requests are welcome. Please open an issue before submitting a pull request for anything beyond a minor fix so we can discuss the approach first.

---

## License

[MIT](LICENSE)