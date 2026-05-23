#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Windows Local Account Manager (WLAM) - Robust local account manager for Windows.

.DESCRIPTION
    Unified local user account manager supporting both an interactive TUI and
    non-interactive CLI/RMM mode. Consolidates account creation, password resets,
    enable/disable, group promotion/demotion, and lock screen visibility into a
    single script. Supports multiple simultaneous actions in one invocation.

.PARAMETER Username
    Target local username. Required for all actions except List.

.PARAMETER Action
    One or more actions to perform. Accepts a comma-separated list or multiple values.
    Valid values:
        List            List all local users with status
        Create          Create a new local user account
        Delete          Delete a local user account
        Enable          Enable a disabled local user account
        Disable         Disable a local user account
        ResetPassword   Reset a user's password
        Promote         Add user to the Administrators group
        Demote          Remove user from the Administrators group
        Hide            Hide user from the Windows lock screen
                        (a sign-out or restart may be required)
        Show            Show user on the Windows lock screen
                        (a sign-out or restart may be required)
        SetInfo         Update the full name and/or description of an existing account

.PARAMETER Password
    Plaintext password for Create or ResetPassword actions.
    If omitted, a cryptographically random password is generated automatically.

.PARAMETER PasswordLength
    Length of the auto-generated random password. Default: 20.

.PARAMETER FullName
    Display/full name for the user account. Used with Create and SetInfo.

.PARAMETER Description
    Account description. Used with Create and SetInfo.

.PARAMETER Admin
    Switch. When used with Create, places the new user in the Administrators group.
    Equivalent to running Create followed by Promote.

.PARAMETER NoPassword
    Switch. When used with Create, the account is created with no password.
    When used with ResetPassword, removes the existing password.

.PARAMETER ClearFullName
    Switch. When used with SetInfo, clears the full name field to blank.

.PARAMETER ClearDescription
    Switch. When used with SetInfo, clears the description field to blank.

.PARAMETER NoMustChangePassword
    Switch. When used with Create and NoPassword, suppresses the default Windows
    behaviour of requiring the user to set a password at next logon.
    Has no effect when a password is provided, as that flag is not set in that case.

.EXAMPLE
    # Launch the interactive TUI (no arguments)
    .\WLAM.ps1

.EXAMPLE
    # List all local accounts
    .\WLAM.ps1 -Action List

.EXAMPLE
    # Create a standard user; password is generated automatically
    .\WLAM.ps1 -Username jdoe -Action Create -FullName "John Doe"

.EXAMPLE
    # Create an admin account with a specific password
    .\WLAM.ps1 -Username svcadmin -Action Create -Password "P@ssw0rd!" -Admin

.EXAMPLE
    # Create a user, hide from lock screen, and enable -- all in one run
    .\WLAM.ps1 -Username svcadmin -Action Create,Hide,Enable -Admin

.EXAMPLE
    # Reset password to a random value and hide from lock screen
    .\WLAM.ps1 -Username jdoe -Action ResetPassword,Hide

.EXAMPLE
    # Promote and enable an existing account
    .\WLAM.ps1 -Username jdoe -Action Promote,Enable

.EXAMPLE
    # Reset password to something specific
    .\WLAM.ps1 -Username jdoe -Action ResetPassword -Password "NewP@ss1"

.EXAMPLE
    # Create an account with no password
    .\WLAM.ps1 -Username jdoe -Action Create -NoPassword

.EXAMPLE
    # Remove a user's password
    .\WLAM.ps1 -Username jdoe -Action ResetPassword -NoPassword

.EXAMPLE
    # Clear a user's full name and set a new description
    .\WLAM.ps1 -Username jdoe -Action SetInfo -ClearFullName -Description "Finance dept"

.EXAMPLE
    # Create an account with no password, no logon password prompt
    .\WLAM.ps1 -Username jdoe -Action Create -NoPassword -NoMustChangePassword

.EXAMPLE
    # Delete an account
    .\WLAM.ps1 -Username olduser -Action Delete

.NOTES
    Requires local Administrator privileges.
    Designed for use with TacticalRMM and similar RMM platforms.
    Lock screen hide/show changes may require a sign-out or restart to take effect.
    Version 1.2.0
#>

param (
    [string]$Username,

    [ValidateSet('List', 'Create', 'Delete', 'Enable', 'Disable',
                 'ResetPassword', 'Promote', 'Demote', 'Hide', 'Show', 'SetInfo')]
    [string[]]$Action,

    [string]$Password,

    [int]$PasswordLength = 20,

    [string]$FullName = '',

    [string]$Description = '',

    [switch]$Admin,

    [switch]$NoPassword,

    [switch]$ClearFullName,

    [switch]$ClearDescription,

    [switch]$NoMustChangePassword
)

$ErrorActionPreference = 'Stop'

#region -- Constants -----------------------------------------------------------

# Update this value when cutting a new release
$Script:Version = '1.2.0'

$RegKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
$AdminSID   = 'S-1-5-32-544'   # Builtin\Administrators
$UsersSID   = 'S-1-5-32-545'   # Builtin\Users

# Canonical execution order when multiple actions are supplied
$ActionOrder = @('Create','Enable','Disable','ResetPassword','SetInfo','Promote','Demote','Hide','Show','Delete','List')

#endregion

#region -- Utility Functions ---------------------------------------------------

function New-RandomPassword {
    param ([int]$Length = 20)

    # Separate pools to guarantee at least one character from each class
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $upper   = 'ABCDEFGHJKLMNOPQRSTUVWXYZ'
    $digits  = '0123456789'
    $special = '!@#$%^&*()-_=+'
    $all     = $lower + $upper + $digits + $special

    $rng   = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = [byte[]]::new($Length + 4)
    $rng.GetBytes($bytes)
    $rng.Dispose()

    $chars = [System.Collections.Generic.List[char]]::new()
    $chars.Add($lower[$bytes[0]   % $lower.Length])
    $chars.Add($upper[$bytes[1]   % $upper.Length])
    $chars.Add($digits[$bytes[2]  % $digits.Length])
    $chars.Add($special[$bytes[3] % $special.Length])
    for ($i = 4; $i -lt ($Length + 4); $i++) {
        $chars.Add($all[$bytes[$i] % $all.Length])
    }

    # Fisher-Yates shuffle so the guaranteed chars are not always at the front
    $rng2 = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $sb   = [byte[]]::new($chars.Count)
    $rng2.GetBytes($sb)
    $rng2.Dispose()
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $sb[$i] % ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $result = [char[]]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) { $result[$i] = $chars[$i] }
    return -join $result
}

function ConvertTo-SecureStringLocal ([string]$Plaintext) {
    return (ConvertTo-SecureString -String $Plaintext -AsPlainText -Force)
}

function Get-LocalUserSafe ([string]$Name) {
    return (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
}

function Assert-UserExists ([string]$Name) {
    $u = Get-LocalUserSafe -Name $Name
    if (-not $u) { throw "User '$Name' does not exist." }
    return $u
}

function Assert-UserNotExists ([string]$Name) {
    if (Get-LocalUserSafe -Name $Name) { throw "User '$Name' already exists." }
}

function Test-IsInGroup ([string]$Name, [string]$GroupSID) {
    try {
        $members = Get-LocalGroupMember -SID $GroupSID -ErrorAction Stop
        return [bool]($members | Where-Object { $_.Name -like "*\$Name" -or $_.Name -eq $Name })
    }
    catch {
        return $false
    }
}

function Test-IsAdmin ([string]$Name) {
    return Test-IsInGroup -Name $Name -GroupSID $AdminSID
}

# Output helpers -- Write-Output keeps RMM stdout clean; colour is added in TUI wrappers
function Write-Info ([string]$Msg) { Write-Output "[INFO]  $Msg" }
function Write-Ok   ([string]$Msg) { Write-Output "[OK]    $Msg" }
function Write-Warn ([string]$Msg) { Write-Output "[WARN]  $Msg" }
function Write-Fail ([string]$Msg) { Write-Output "[ERROR] $Msg" }

#endregion

#region -- Action Functions ----------------------------------------------------

function Invoke-ListUsers {
    Write-Info 'Local user accounts on this machine:'
    $rows = Get-LocalUser | ForEach-Object {
        $isAdmin = Test-IsAdmin -Name $_.Name
        $hidden  = $false
        if (Test-Path -LiteralPath $RegKeyPath) {
            $prop = Get-ItemProperty -LiteralPath $RegKeyPath -Name $_.Name -ErrorAction SilentlyContinue
            if ($prop -and $prop.($_.Name) -eq 0) { $hidden = $true }
        }
        [PSCustomObject]@{
            Name        = $_.Name
            Enabled     = if ($_.Enabled) { 'Yes' } else { 'No' }
            Admin       = if ($isAdmin)   { 'Yes' } else { 'No' }
            Hidden      = if ($hidden)    { 'Yes' } else { 'No' }
            FullName    = $_.FullName
            Description = $_.Description
        }
    }
    ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
}

function Invoke-CreateUser {
    param (
        [string]$Name,
        [string]$PlainPassword,
        [string]$UserFullName,
        [string]$UserDescription,
        [bool]$MakeAdmin,
        [bool]$NoPassword,
        [bool]$NoMustChangePassword
    )
    Assert-UserNotExists -Name $Name
    if ($NoPassword) {
        New-LocalUser -Name $Name `
                      -NoPassword `
                      -FullName $UserFullName `
                      -Description $UserDescription | Out-Null
        # -PasswordNeverExpires cannot be combined with -NoPassword in New-LocalUser,
        # so we set it immediately after creation
        Set-LocalUser -Name $Name -PasswordNeverExpires $true
        if ($NoMustChangePassword) {
            # The LocalAccounts module has no direct parameter to clear this flag;
            # ADSI is the reliable cross-version approach
            $adsiUser = [adsi]"WinNT://$env:COMPUTERNAME/$Name,user"
            $adsiUser.PasswordExpired = 0
            $adsiUser.SetInfo()
            Write-Info "Must-change-password at next logon disabled for '$Name'."
        }
    }
    else {
        $securePass = ConvertTo-SecureStringLocal -Plaintext $PlainPassword
        New-LocalUser -Name $Name `
                      -Password $securePass `
                      -FullName $UserFullName `
                      -Description $UserDescription `
                      -PasswordNeverExpires | Out-Null
    }
    if ($MakeAdmin) {
        Add-LocalGroupMember -SID $AdminSID -Member $Name
        Write-Ok "Created user '$Name' and added to Administrators."
    }
    else {
        Add-LocalGroupMember -SID $UsersSID -Member $Name
        Write-Ok "Created user '$Name' and added to Users."
    }
    if ($NoPassword) { Write-Info 'No password set.' }
    else             { Write-Info "Password: $PlainPassword" }
}

function Invoke-DeleteUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    Remove-LocalUser -Name $Name
    Write-Ok "Deleted user '$Name'."
    if (Test-Path -LiteralPath $RegKeyPath) {
        $prop = Get-ItemProperty -LiteralPath $RegKeyPath -Name $Name -ErrorAction SilentlyContinue
        if ($prop) {
            Remove-ItemProperty -LiteralPath $RegKeyPath -Name $Name -Force
            Write-Info "Removed orphaned lock screen registry entry for '$Name'."
        }
    }
}

function Invoke-EnableUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    Enable-LocalUser -Name $Name
    Write-Ok "Enabled account '$Name'."
}

function Invoke-DisableUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    Disable-LocalUser -Name $Name
    Write-Ok "Disabled account '$Name'."
}

function Invoke-ResetPassword ([string]$Name, [string]$PlainPassword, [bool]$NoPassword) {
    $user = Assert-UserExists -Name $Name
    if ($NoPassword) {
        $user | Set-LocalUser -Password (New-Object System.Security.SecureString)
        Write-Ok "Password removed for '$Name'."
    }
    else {
        $user | Set-LocalUser -Password (ConvertTo-SecureStringLocal -Plaintext $PlainPassword)
        Write-Ok "Password reset for '$Name'."
        Write-Info "New password: $PlainPassword"
    }
}

function Invoke-SetUserInfo {
    param (
        [string]$Name,
        [string]$UserFullName,
        [string]$UserDescription,
        [bool]$ClearFullName,
        [bool]$ClearDescription
    )
    Assert-UserExists -Name $Name | Out-Null

    $params = @{}

    if ($ClearFullName) {
        $params['FullName'] = ''
    }
    elseif (-not [string]::IsNullOrEmpty($UserFullName)) {
        $params['FullName'] = $UserFullName
    }

    if ($ClearDescription) {
        $params['Description'] = ''
    }
    elseif (-not [string]::IsNullOrEmpty($UserDescription)) {
        $params['Description'] = $UserDescription
    }

    if ($params.Count -eq 0) {
        Write-Warn "SetInfo requires at least one of -FullName, -Description, -ClearFullName, or -ClearDescription."
        return
    }

    Set-LocalUser -Name $Name @params

    if ($params.ContainsKey('FullName')) {
        if ($ClearFullName) { Write-Ok "Full name cleared for '$Name'." }
        else                { Write-Ok "Full name updated for '$Name': $UserFullName" }
    }
    if ($params.ContainsKey('Description')) {
        if ($ClearDescription) { Write-Ok "Description cleared for '$Name'." }
        else                   { Write-Ok "Description updated for '$Name': $UserDescription" }
    }
}

function Invoke-PromoteUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    if (Test-IsAdmin -Name $Name) {
        Write-Warn "User '$Name' is already in the Administrators group."
        return
    }
    Add-LocalGroupMember -SID $AdminSID -Member $Name
    Write-Ok "Promoted '$Name' to Administrator."
}

function Invoke-DemoteUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    if (-not (Test-IsAdmin -Name $Name)) {
        Write-Warn "User '$Name' is not in the Administrators group."
        return
    }
    Remove-LocalGroupMember -SID $AdminSID -Member $Name
    Write-Ok "Demoted '$Name' from Administrator."
    if (-not (Test-IsInGroup -Name $Name -GroupSID $UsersSID)) {
        Add-LocalGroupMember -SID $UsersSID -Member $Name
        Write-Info "Added '$Name' to Users group."
    }
}

function Invoke-HideUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    if (-not (Test-Path -LiteralPath $RegKeyPath)) {
        New-Item -Path $RegKeyPath -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $RegKeyPath -Name $Name -Value 0 `
                     -PropertyType DWord -Force | Out-Null
    Write-Ok "User '$Name' will be hidden on the lock screen. A sign-out or restart may be required."
}

function Invoke-ShowUser ([string]$Name) {
    Assert-UserExists -Name $Name | Out-Null
    if (Test-Path -LiteralPath $RegKeyPath) {
        $prop = Get-ItemProperty -LiteralPath $RegKeyPath -Name $Name -ErrorAction SilentlyContinue
        if ($prop) {
            New-ItemProperty -LiteralPath $RegKeyPath -Name $Name -Value 1 `
                             -PropertyType DWord -Force | Out-Null
            Write-Ok "User '$Name' will be shown on the lock screen. A sign-out or restart may be required."
            return
        }
    }
    Write-Warn "No hidden entry found for '$Name' -- already visible or never hidden."
}

#endregion

#region -- Non-Interactive Dispatcher ------------------------------------------

function Show-UserInfo ([string]$Name) {
    $user    = Assert-UserExists -Name $Name
    $isAdmin = Test-IsAdmin -Name $Name
    $isHidden = $false
    if (Test-Path -LiteralPath $RegKeyPath) {
        $prop = Get-ItemProperty -LiteralPath $RegKeyPath -Name $Name -ErrorAction SilentlyContinue
        if ($prop -and $prop.$Name -eq 0) { $isHidden = $true }
    }
    Write-Info "Account information for '$Name':"
    Write-Output "  Enabled     : $(if ($user.Enabled) {'Yes'} else {'No'})"
    Write-Output "  Admin       : $(if ($isAdmin)      {'Yes'} else {'No'})"
    Write-Output "  Hidden      : $(if ($isHidden)     {'Yes'} else {'No'})"
    Write-Output "  Full Name   : $(if ($user.FullName)    {$user.FullName}    else {'(none)'})"
    Write-Output "  Description : $(if ($user.Description) {$user.Description} else {'(none)'})"
}

function Invoke-Actions {
    param (
        [string[]]$Actions,
        [string]$Name,
        [string]$PlainPassword,
        [int]$PwLength,
        [string]$UserFullName,
        [string]$UserDescription,
        [bool]$MakeAdmin,
        [bool]$NoPassword,
        [bool]$ClearFullName,
        [bool]$ClearDescription,
        [bool]$NoMustChangePassword
    )

    # Sort into a safe logical execution order regardless of what the caller supplied
    $ordered = $ActionOrder | Where-Object { $_ -in $Actions }

    # Generate a password only if needed and not explicitly suppressed by -NoPassword
    $pwActions = @('Create', 'ResetPassword')
    $needsPw   = $ordered | Where-Object { $_ -in $pwActions }
    if ($needsPw -and -not $NoPassword -and [string]::IsNullOrEmpty($PlainPassword)) {
        $PlainPassword = New-RandomPassword -Length $PwLength
        Write-Info "No password provided -- generated a random $PwLength-character password."
    }

    foreach ($a in $ordered) {
        Write-Info "--- Action: $a ---"
        switch ($a) {
            'List'          { Invoke-ListUsers }
            'Create'        { Invoke-CreateUser -Name $Name -PlainPassword $PlainPassword -UserFullName $UserFullName -UserDescription $UserDescription -MakeAdmin $MakeAdmin -NoPassword $NoPassword -NoMustChangePassword $NoMustChangePassword }
            'Delete'        { Invoke-DeleteUser -Name $Name }
            'Enable'        { Invoke-EnableUser -Name $Name }
            'Disable'       { Invoke-DisableUser -Name $Name }
            'ResetPassword' { Invoke-ResetPassword -Name $Name -PlainPassword $PlainPassword -NoPassword $NoPassword }
            'SetInfo'       { Invoke-SetUserInfo -Name $Name -UserFullName $UserFullName -UserDescription $UserDescription -ClearFullName $ClearFullName -ClearDescription $ClearDescription }
            'Promote'       { Invoke-PromoteUser -Name $Name }
            'Demote'        { Invoke-DemoteUser -Name $Name }
            'Hide'          { Invoke-HideUser -Name $Name }
            'Show'          { Invoke-ShowUser -Name $Name }
        }
    }
}

#endregion

#region -- TUI -----------------------------------------------------------------

function Write-TuiBanner {
    Clear-Host
    Write-Host ''
    Write-Host '  +-------------------------------------------+' -ForegroundColor Cyan
    Write-Host ('  |    WLAM v{0} - Local Account Manager    |' -f $Script:Version) -ForegroundColor Cyan
    Write-Host '  +-------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
}

function Write-TuiSection ([string]$Title) {
    Write-Host ''
    Write-Host "  -- $Title --" -ForegroundColor DarkCyan
}

function Read-TuiChoice ([string]$Prompt, [string[]]$Valid) {
    while ($true) {
        $choice = (Read-Host "  $Prompt").Trim()
        if ($choice -in $Valid) { return $choice }
        Write-Host '  Invalid selection. Please try again.' -ForegroundColor Yellow
    }
}

function Read-TuiNonEmpty ([string]$Prompt) {
    while ($true) {
        $val = (Read-Host "  $Prompt").Trim()
        if ($val) { return $val }
        Write-Host '  Value cannot be empty.' -ForegroundColor Yellow
    }
}

function Read-TuiExistingUser {
    while ($true) {
        $name = Read-TuiNonEmpty -Prompt 'Username'
        if (Get-LocalUserSafe -Name $name) { return $name }
        Write-Host "  User '$name' not found. Try again." -ForegroundColor Yellow
    }
}

function Read-TuiPassword ([string]$Context = 'Password') {
    Write-Host "  $Context`:  [1] Generate random   [2] Enter manually   [3] No password"
    $c = Read-TuiChoice -Prompt 'Choice' -Valid @('1', '2', '3')
    switch ($c) {
        '1' { return New-RandomPassword -Length 20 }
        '2' { return Read-TuiNonEmpty -Prompt 'Password' }
        '3' { return $null }
    }
}

function Show-TuiUserTable {
    Write-TuiSection 'Current Local Users'
    $rows = Get-LocalUser | ForEach-Object {
        $isAdmin = Test-IsAdmin -Name $_.Name
        $hidden  = $false
        if (Test-Path -LiteralPath $RegKeyPath) {
            $prop = Get-ItemProperty -LiteralPath $RegKeyPath -Name $_.Name -ErrorAction SilentlyContinue
            if ($prop -and $prop.($_.Name) -eq 0) { $hidden = $true }
        }
        [PSCustomObject]@{
            Name    = $_.Name
            Enabled = if ($_.Enabled) { 'Yes' } else { 'No' }
            Admin   = if ($isAdmin)   { 'Yes' } else { 'No' }
            Hidden  = if ($hidden)    { 'Yes' } else { 'No' }
        }
    }
    Write-Host ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
}

function Invoke-TuiPause {
    Write-Host ''
    Write-Host '  Press Enter to continue...' -ForegroundColor DarkGray
    $null = Read-Host
}

function Invoke-TuiResult ([string]$Text) {
    Write-Host "  $Text" -ForegroundColor Green
}

function Invoke-TuiError ([string]$Text) {
    Write-Host "  Error: $Text" -ForegroundColor Red
}

# -- TUI: Create User ----------------------------------------------------------

function Invoke-TuiCreateUser {
    Write-TuiBanner
    Write-TuiSection 'Create New User'

    $name = Read-TuiNonEmpty -Prompt 'Username'
    if (Get-LocalUserSafe -Name $name) {
        Write-Host "  User '$name' already exists." -ForegroundColor Red
        Invoke-TuiPause
        return
    }

    $fullName = (Read-Host '  Full name (Enter to skip)').Trim()
    $desc     = (Read-Host '  Description (Enter to skip)').Trim()

    Write-Host ''
    Write-Host '  Account type:  [1] Standard User   [2] Administrator'
    $makeAdmin = (Read-TuiChoice -Prompt 'Choice' -Valid @('1', '2')) -eq '2'

    $pw              = Read-TuiPassword -Context 'Password'
    $noPw            = ($null -eq $pw)
    $noMustChangePw  = $false

    if ($noPw) {
        Write-Host ''
        Write-Host '  Require password change at next logon?  [1] Yes (default)   [2] No'
        $noMustChangePw = (Read-TuiChoice -Prompt 'Choice' -Valid @('1','2')) -eq '2'
    }

    try {
        Invoke-CreateUser -Name $name `
                          -PlainPassword $(if ($noPw) { '' } else { $pw }) `
                          -UserFullName $fullName `
                          -UserDescription $desc `
                          -MakeAdmin $makeAdmin `
                          -NoPassword $noPw `
                          -NoMustChangePassword $noMustChangePw
        Write-Host ''
        Write-Host "  [OK] Created : $name" -ForegroundColor Green
        Write-Host "       Password: $(if ($noPw) {'(none)'} else {$pw})" -ForegroundColor Green
        Write-Host "       Admin   : $(if ($makeAdmin) {'Yes'} else {'No'})" -ForegroundColor Green
    }
    catch {
        Invoke-TuiError $_
    }
    Invoke-TuiPause
}

# -- TUI: Manage Existing User -------------------------------------------------

function Invoke-TuiManageUser {
    Write-TuiBanner
    Show-TuiUserTable
    Write-Host ''
    $name = Read-TuiExistingUser

    while ($true) {
        Write-TuiBanner
        Write-TuiSection "Managing: $name"

        $user = Get-LocalUserSafe -Name $name
        if (-not $user) {
            Write-Host "  User '$name' no longer exists." -ForegroundColor Red
            Invoke-TuiPause
            return
        }

        $isAdmin   = Test-IsAdmin -Name $name
        $isEnabled = $user.Enabled
        $isHidden  = $false
        if (Test-Path -LiteralPath $RegKeyPath) {
            $prop = Get-ItemProperty -LiteralPath $RegKeyPath -Name $name -ErrorAction SilentlyContinue
            if ($prop -and $prop.$name -eq 0) { $isHidden = $true }
        }

        Write-Host "  Enabled : $(if ($isEnabled) {'Yes'} else {'No'})"
        Write-Host "  Admin   : $(if ($isAdmin)   {'Yes'} else {'No'})"
        Write-Host "  Hidden  : $(if ($isHidden)  {'Yes (sign-out or restart may be required)'} else {'No'})"
        Write-Host ''
        Write-Host '    [1] Reset Password'
        Write-Host '    [2] Enable Account'
        Write-Host '    [3] Disable Account'
        Write-Host '    [4] Promote to Administrator'
        Write-Host '    [5] Demote from Administrator'
        Write-Host '    [6] Hide on Lock Screen'
        Write-Host '    [7] Show on Lock Screen'
        Write-Host '    [8] Delete Account'
        Write-Host '    [9] Update Full Name / Description'
        Write-Host '    [0] Back to Main Menu'
        Write-Host ''

        $choice = Read-TuiChoice -Prompt 'Action' -Valid @('1','2','3','4','5','6','7','8','9','0')
        if ($choice -eq '0') { return }

        try {
            switch ($choice) {
                '1' {
                    $pw   = Read-TuiPassword -Context 'New Password'
                    $noPw = ($null -eq $pw)
                    Invoke-ResetPassword -Name $name -PlainPassword $(if ($noPw) {''} else {$pw}) -NoPassword $noPw
                    if ($noPw) { Write-Host '  Password removed.' -ForegroundColor Green }
                    else       { Write-Host "  New password: $pw" -ForegroundColor Green }
                }
                '2' { Invoke-EnableUser  -Name $name; Invoke-TuiResult 'Account enabled.' }
                '3' { Invoke-DisableUser -Name $name; Invoke-TuiResult 'Account disabled.' }
                '4' { Invoke-PromoteUser -Name $name; Invoke-TuiResult 'Promoted to Administrator.' }
                '5' { Invoke-DemoteUser  -Name $name; Invoke-TuiResult 'Demoted from Administrator.' }
                '6' { Invoke-HideUser    -Name $name; Invoke-TuiResult 'Hidden. A sign-out or restart may be required.' }
                '7' { Invoke-ShowUser    -Name $name; Invoke-TuiResult 'Shown. A sign-out or restart may be required.' }
                '8' {
                    $confirm = (Read-Host "  Type 'yes' to confirm deletion of '$name'").Trim()
                    if ($confirm -eq 'yes') {
                        Invoke-DeleteUser -Name $name
                        Invoke-TuiResult "Account '$name' deleted."
                        Invoke-TuiPause
                        return
                    }
                    else {
                        Write-Host '  Cancelled.' -ForegroundColor Yellow
                    }
                }
                '9' {
                    $currentUser = Get-LocalUserSafe -Name $name
                    $clearFN     = $false
                    $clearDesc   = $false
                    $newFN       = ''
                    $newDesc     = ''

                    Write-Host "  Current full name  : $(if ($currentUser.FullName)    {$currentUser.FullName}    else {'(none)'})"
                    Write-Host '    [1] Keep current   [2] Set new value   [3] Clear'
                    $fnChoice = Read-TuiChoice -Prompt 'Choice' -Valid @('1','2','3')
                    if     ($fnChoice -eq '2') { $newFN   = Read-TuiNonEmpty -Prompt 'New full name' }
                    elseif ($fnChoice -eq '3') { $clearFN = $true }

                    Write-Host "  Current description: $(if ($currentUser.Description) {$currentUser.Description} else {'(none)'})"
                    Write-Host '    [1] Keep current   [2] Set new value   [3] Clear'
                    $descChoice = Read-TuiChoice -Prompt 'Choice' -Valid @('1','2','3')
                    if     ($descChoice -eq '2') { $newDesc   = Read-TuiNonEmpty -Prompt 'New description' }
                    elseif ($descChoice -eq '3') { $clearDesc = $true }

                    Invoke-SetUserInfo -Name $name -UserFullName $newFN -UserDescription $newDesc `
                                       -ClearFullName $clearFN -ClearDescription $clearDesc
                }
            }
        }
        catch {
            Invoke-TuiError $_
        }

        Invoke-TuiPause
    }
}

# -- TUI: Main Loop ------------------------------------------------------------

function Invoke-TUI {
    while ($true) {
        Write-TuiBanner
        Show-TuiUserTable
        Write-Host ''
        Write-Host '  Main Menu'
        Write-Host '  ---------'
        Write-Host '    [1] Refresh User List'
        Write-Host '    [2] Create New User'
        Write-Host '    [3] Manage Existing User'
        Write-Host '    [4] Exit'
        Write-Host ''

        $choice = Read-TuiChoice -Prompt 'Selection' -Valid @('1','2','3','4')

        switch ($choice) {
            '1' { <# loop back to top -- table redraws automatically #> }
            '2' { Invoke-TuiCreateUser }
            '3' { Invoke-TuiManageUser }
            '4' {
                Write-Host ''
                Write-Host '  Goodbye.' -ForegroundColor DarkGray
                Write-Host ''
                exit 0
            }
        }
    }
}

#endregion

#region -- Entry Point ---------------------------------------------------------

if (-not $Action) {
    if (-not [string]::IsNullOrEmpty($Username)) {
        # -Username provided without -Action: show account info rather than crashing into TUI
        Write-Info "WLAM v$($Script:Version)"
        try {
            Show-UserInfo -Name $Username
            exit 0
        }
        catch {
            Write-Fail $_
            exit 1
        }
    }
    Invoke-TUI
    exit 0
}

Write-Info "WLAM v$($Script:Version)"

# Non-interactive: ensure a username is present for every action that needs one
$actionsNeedingUser = $Action | Where-Object { $_ -ne 'List' }
if ($actionsNeedingUser -and [string]::IsNullOrEmpty($Username)) {
    Write-Fail "A -Username is required for: $($actionsNeedingUser -join ', ')"
    exit 1
}

try {
    Invoke-Actions -Actions $Action `
                   -Name $Username `
                   -PlainPassword $Password `
                   -PwLength $PasswordLength `
                   -UserFullName $FullName `
                   -UserDescription $Description `
                   -MakeAdmin $Admin.IsPresent `
                   -NoPassword $NoPassword.IsPresent `
                   -ClearFullName $ClearFullName.IsPresent `
                   -ClearDescription $ClearDescription.IsPresent `
                   -NoMustChangePassword $NoMustChangePassword.IsPresent
    exit 0
}
catch {
    Write-Fail $_
    exit 1
}

#endregion
