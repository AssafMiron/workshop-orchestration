Import-Module psPAS
Import-Module ActiveDirectory

# Set the script path to a variable in case it is run from another path
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

# Import XML Configuration Settings from config.xml
try {
    [xml]$configFile = Get-Content "${scriptDir}\config.xml"
} catch {
    Write-Error $_
    Write-Error "config.xml is not present in the script directory." -ErrorAction Stop
}

# Test config.xml Values
if ($configFile.Settings.AttendeeCount -le 0 -or !$configFile.Settings.AttendeeCount) {
    Write-Error "Settings.AttendeeCount in config.xml must be greater than zero." -ErrorAction Stop
}
try {
    New-Item -Type file $configFile.Settings.CSVExportPath
} catch {
    Write-Error $_
    Write-Error "Settings.CSVExportPath must be a valid file path within config.xml."
    Write-Error "If the path exists, please check NTFS permissions." -ErrorAction Stop
}
if (!$configFile.API.BaseURL -or $configFile.API.BaseURL -notmatch "http") {
    Write-Error "Settings.API.BaseURL must be a valid URL beginning with https:// or http:// in config.xml." -ErrorAction Stop
}
if (!$configFile.API.AuthType -or $configFile.API.AuthType.ToLower() -ne "ldap" -or !$configFile.API.AuthType.ToLower() -ne "windows" -or !$configFile.API.AuthType.ToLower() -ne "cyberark" -or !$configFile.API.AuthType.ToLower() -ne "radius") {
    Write-Error "Settings.API.AuthType must match cyberark, ldap, windows, or radius in config.xml." -ErrorAction Stop
}
if (!$configFile.ActiveDirectory.Domain) {
    Write-Error "Settings.ActiveDirectory.Domain must be present in config.xml."
}
if (!$configFile.ActiveDirectory.UsersPath) {
    Write-Error "Settings.ActiveDirectory.UsersPath must be present in config.xml."
}
if (!$configFile.ActiveDirectory.CyberArkUsers) {
    Write-Error "Settings.ActiveDirectory.CyberArkUsers must be present in config.xml."
}
if (!$configFile.CyberArk.ManagingCPM) {
    Write-Error "Settings.CyberArk.ManagingCPM must be present in config.xml."
}
if (!$configFile.CyberArk.PlatformID) {
    Write-Error "Settings.CyberArk.PlatformID must be present in config.xml."
}

# Cleanup pre-existing exported CSV
Remove-Item -Path $configFile.Settings.CSVExportPath -ErrorAction SilentlyContinue | Out-Null

Write-Host "==> Starting deployment" -ForegroundColor Green
Write-Host ""

# Logon to PAS REST API
Write-Host "==> Creating REST API session" -ForegroundColor Yellow
try {
    New-PASSession -BaseURI $configFile.Settings.API.BaseURL -Type $configFile.Settings.API.AuthType -Credential $(Get-Credential)
} catch {
    Write-Error $_
    Write-Error "There was a problem creating an API session with CyberArk PAS." -ErrorAction Stop
}

# Set count for do...until loop to 0
$count = 0

# Begin doing the following command block until the count var...
# ... equals the total number of attendees declared in config.xml
do {
    # Increase counter by one
    $count++
    # Set loop variables
    $adUsername         = "User${count}"
    $adPassword         = "4ut0m4t!0n${count}727"
    $pasSafeName        = "RESTAPIWorkshop${count}"
    $pasAppID           = "RESTAPIWorkshop${count}"
    # Save details into PSObject for export to CSV later...
    # ... also set initial values for reporting workshop object creation...
    # ... to False until they are successfully completed.
    $workshopUserInfo   = New-Object PSObject
    # Attendee Details
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name Username -Value $adUsername
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name Password -Value $adPassword
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name Safe -Value $pasSafeName
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name AppID -Value $pasAppID
    # Deployment Details
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name ADUser -Value "False"
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name CreateSafe -Value "False"
    $workshopUserInfo | Add-Member -MemberType NoteProperty -Name CreateAppID -Value "False"

    # Create hash table of parameters to splat into New-ADUser cmdlet
    $newADUser = @{
        Name                    = $adUsername
        ChangePasswordAtLogon   = $False
        Description             = "REST API Workshop User ${count}"
        DisplayName             = "User ${count}"
        PasswordNeverExpires    = $True
        Enabled                 = $True
        Path                    = $configFile.Settings.ActiveDirectory.UsersPath
        SamAccountName          = $adUsername
        AccountPassword         = $(ConvertTo-SecureString $adPassword -AsPlainText -Force)
        UserPrincipalName       = "${adUsername}@${configFile.Settings.ActiveDirectory.Domain}"
    }
    Write-Host "==> Creating Active Directory User Object ${adUsername}" -ForegroundColor Yellow
    # Create user object in Active Directory
    try {
        New-ADUser @newADUser | Out-Null
        # If successfully created, flip deployment detail from False to True
        $workshopUserInfo.ADUser = "True"
    } catch {
        # If unsuccessful, throw error messages and stop the script
        Write-Error $_
        Write-Error "Active Directory User Object could not be created." -ErrorAction Stop
    }

    Write-Host "==> Add ${adUsername} to ${configFile.Settings.ActiveDirectory.CyberArkUsers}" -ForegroundColor Yellow
    # Add the new AD user to the CyberArk Users security group as defined in config.xml
    try {
        Add-ADGroupMember -Identity $configFile.Settings.ActiveDirectory.CyberArkUsers -Members $adUsername | Out-Null
    } catch {
        Write-Error $_
        Write-Error "Active Directory User Object could not be added to CyberArk Users AD Security Group." -ErrorAction Stop
    }

    Write-Host "==> Adding safe ${pasSafeName}" -ForegroundColor Yellow
    # Create hash table of parameters to splat into the Add-PASSafe cmdlet
    $addSafe = @{
        SafeName                = $pasSafeName
        Description             = "REST API Workshop Safe for User ${count}"
        ManagingCPM             = $configFile.Settings.CyberArk.ManagingCPM
        # NumberOfDaysRetention to 0 allows for immediate deletion of the safe...
        # ... and all account objects stored within.
        NumberOfDaysRetention   = 0
        # ErrorAction set to SilentlyContinue will suppress an error caused...
        # ... when the safe already exists and the script will continue.
        ErrorAction             = SilentlyContinue
    }
    # Add the safe in EPV
    Add-PASSafe @addSafe | Out-Null
    # If successfully created or already present, flip deployment detail from False to True
    $workshopUserInfo.CreateSafe = "True"

    # Create hash table of parameters to splat into Add-PASSafeMember cmdlet
    $addSafeMember = @{
        SafeName                                = $pasSafeName
        MemberName                              = $adUsername
        SearchIn                                = $configFile.Settings.ActiveDirectory.Domain
        UseAccounts                             = $True
        RetrieveAccounts                        = $True
        ListAccounts                            = $True
        AddAccounts                             = $True
        UpdateAccountContent                    = $True
        UpdateAccountProperties                 = $True
        InitiateCPMAccountManagementOperations  = $True
        SpecifyNextAccountContent               = $True
        RenameAccounts                          = $True
        DeleteAccounts                          = $True
        UnlockAccounts                          = $True
        ManageSafe                              = $False
        ManageSafeMembers                       = $False
        BackupSafe                              = $False
        ViewAuditLog                            = $True
        ViewSafeMembers                         = $True
        RequestsAuthorizationLevel              = 0
        AccessWithoutConfirmation               = $True
        CreateFolders                           = $False
        DeleteFolders                           = $False
        MoveAccountsAndFolders                  = $False
    }
    Write-Host "==> Adding ${adUsername} as Safe Owner of ${pasSafeName}" -ForegroundColor Yellow
    try {
        # Add the new AD user as a member of the safe...
        # ... this is also where the EPVUser license is consumed by the new AD user.
        Add-PASSafeMember @addSafeMember | Out-Null
    } catch {
        Write-Error $_
        Write-Error "Active Directory User could not be added to CyberArk Safe as Safe Owner." -ErrorAction Stop
    }

    # Create hash table of parameters to splat into Add-PASApplication cmdlet
    $addApplication = @{
        AppID               = $pasAppID
        Description         = "REST API Workshop Application ID for User ${count}"
        Location            = "\Applications"
        # Access is only allowed from 9am - 5pm to the Application ID credentials
        AccessPermittedFrom = 9
        AccessPermittedTo   = 17
    }
    Write-Host "==> Creating $pasAppID Application ID" -ForegroundColor Yellow
    try {
        # Add a new Application ID
        Add-PASApplication @addApplication | Out-Null
        # If successfully created, flip deployment detail from False to True
        $workshopUserInfo.CreateAppID = "True"
    } catch {
        Write-Error $_
        Write-Error "Application Identity could not be created." -ErrorAction Stop
    }
    Write-Host "==> Adding Machine Address for 0.0.0.0 on ${pasAppID}" -ForegroundColor Yellow
    try {
        # Add a machineAddress IP of 0.0.0.0 to completely open the App ID up to anyone
        Add-PASApplicationAuthenticationMethod -AppID $pasAppID -machineAddress "0.0.0.0" | Out-Null
    } catch {
        Write-Error $_
        Write-Error "Application Identity Authentication Method could not be added." -ErrorAction Stop
    }

    # Check that MOCK_DATA.csv exists in the script directory
    if ($(Test-Path -Path "${scriptDir}\MOCK_DATA.csv")) {
        # If it does, we import the CSV data
        $mockAccounts = Import-Csv -Path "${scriptDir}\MOCK_DATA.csv"
    } else {
        Write-Error "Could not find MOCK_DATA.csv in the script's directory." -ErrorAction Stop
    }

    # This foreach loop will iterate through each row of the CSV containing mock account details
    # It will create an account in the safe previously created for each row
    foreach ($account in $mockAccounts) {
        # Create hash table of parameters to splat into Add-PASAccount based on the current row...
        # ... being read in the CSV.
        $addAccount = @{
            address                     = $configFile.Settings.ActiveDirectory.Domain
            username                    = $account.username
            platformID                  = $configFile.Settings.CyberArk.PlatformID
            SafeName                    = $pasSafeName
            automaticManagementEnabled  = $False
            secretType                  = "password"
            secret                      = $(ConvertTo-SecureString $([System.Web.Security.Membership]::GeneratePassword(8, 3)) -AsPlainText -Force)
        }
        Write-Host "==> Adding account object for ${account} to ${pasSafeName}" -ForegroundColor Yellow
        try {
            # Create the account object in our previously created safe
            Add-PASAccount @addAccount | Out-Null
        } catch {
            Write-Error $_
            Write-Error "Could not create dummy user ${account.username} in CyberArk Safe." -ErrorAction Stop
        }
    }

    # All attendee and deployment details are exported to a CSV file via append.
    # This will allow us to have a full report for after all environments are deployed.
    Export-Csv -Path $configFile.Settings.CSVExportPath -InputObject $workshopUserInfo -NoTypeInformation -Force -Append -ErrorAction SilentlyContinue
    # To be on the safe side, removing the variable should clear it out for the next loop.
    Remove-Variable workshopUserInfo

} until ($count -eq $configFile.Settings.AttendeeCount)

Write-Host "==> Closed REST API session" -ForegroundColor Yellow
# Logoff the PAS REST API after completing the do...until loop.
Close-PASSession

Write-Host ""
Write-Host "==> Deployment complete" -ForegroundColor Green

Write-Host "==> Wrote Workshop Details to ${configFile.Settings.CSVExportPath}" -ForegroundColor Cyan