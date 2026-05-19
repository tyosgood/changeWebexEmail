# ============================================================
# Webex User Email Domain Update Script (SCIM API + CSV Input)
# Description: Updates email addresses for Webex users via
#              the Webex SCIM2 API using a CSV file as input
#              Specifically tested / works with FedRAMP Webex
# SCIM Spec:   RFC 7643 / RFC 7644
# ============================================================

# --- Configuration ---
$ApiToken    = "WEBEX DEV TOKEN HERE - GET from developer-usgov.webex.com"
$OrgId       = "ORG_ID from Control Hub"
$NewDomain   = "newdomain.com"
$CsvFilePath = "users.csv"
$WhatIfMode  = $true   # Set to $false to apply actual changes

# --- SCIM API Base URL ---
# had to specify fedramp url and change url structure from AI generated URL
$ScimBaseUrl = "https://api-usgov.webex.com/identity/scim/$OrgId/v2/Users"


# --- Headers --- Had to change because AI is dumb
$Headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"

$Headers.Add("Authorization","Bearer $ApiToken")
$Headers.Add("Content-Type" , "application/scim+json")
$Headers.Add("Accept" , "application/scim+json")

<# $Headers = @{
    "Authorization" = "Bearer $ApiToken"
    "Content-Type"  = "application/scim+json"
    "Accept"        = "application/scim+json"
}
 #>
# --- Log File ---
$LogFile = "WebexSCIM_EmailUpdate_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# --- Summary Counters ---
$Stats = @{
    Total   = 0
    Updated = 0
    Skipped = 0
    Failed  = 0
    WhatIf  = 0
}

# ============================================================
# HELPER: Write Log Entry
# ============================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry     = "[$Timestamp] [$Level] $Message"

    $Color = switch ($Level) {
        "SUCCESS" { "Green"   }
        "ERROR"   { "Red"     }
        "WARN"    { "Yellow"  }
        "SKIP"    { "Cyan"    }
        "WHATIF"  { "Magenta" }
        default   { "White"   }
    }

    Write-Host $Entry -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $Entry
}

# ============================================================
# HELPER: Validate Email Format
# ============================================================
function Test-EmailFormat {
    param([string]$Email)
    return $Email -match '^[\w\.\-\+]+@[\w\-]+\.[a-zA-Z]{2,}$'
}

# ============================================================
# STEP 1: Validate and Load CSV File
# ============================================================
function Import-UserCsv {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        Write-Log "CSV file not found at path: $FilePath" "ERROR"
        exit 1
    }

    try {
        $CsvData = Import-Csv -Path $FilePath

        if (-not ($CsvData | Get-Member -Name "CurrentEmail")) {
            Write-Log "CSV is missing required column: 'CurrentEmail'" "ERROR"
            exit 1
        }

        $ValidRows = $CsvData | Where-Object {
            $_.CurrentEmail -ne "" -and $null -ne $_.CurrentEmail
        }

        Write-Log "CSV loaded successfully. Valid rows found: $($ValidRows.Count)"
        return $ValidRows

    } catch {
        Write-Log "Failed to read CSV file: $_" "ERROR"
        exit 1
    }
}

# ============================================================
# STEP 2: Look Up SCIM User by Email (Filter Query)
# ============================================================
function Get-ScimUserByEmail {
    param([string]$Email)

    try {
        # --- Build SCIM filter query ---
        # had to change URL filter structure to work with webex API
        $Filter      = [System.Web.HttpUtility]::UrlEncode("userName eq `"$Email`"")
        $LookupUrl   = "$ScimBaseUrl`?filter=$Filter&attributes=id,userName,emails,displayName"

        $Response = Invoke-RestMethod -Uri $LookupUrl -Headers $Headers -Method GET

        if ($Response.totalResults -eq 0 -or $Response.Resources.Count -eq 0) {
            Write-Log "No SCIM user found for: $Email" "WARN"
            return $null
        }

        return $Response.Resources[0]

    } catch {
        Write-Log "Error looking up SCIM user $Email : $_" "ERROR"
        return $null
    }
}

# ============================================================
# STEP 3: Build SCIM PATCH Payload (RFC 7644)
# ============================================================
function Build-ScimPatchPayload {
    param(
        [string]$NewEmail,
        [string]$CurrentUserName
    )

    # --- Derive new userName (typically matches primary email) ---
    $NewUserName = $CurrentUserName -replace [regex]::Escape(($CurrentUserName -split "@")[1]), $NewDomain

    $Payload = @{
        schemas    = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
        Operations = @(
            @{
                op    = "replace"
                path  = "emails[type eq `"work`"].value"
                value = $NewEmail
            },
            @{
                op    = "replace"
                path  = "userName"
                value = $NewUserName
            }
        )
    }

    return $Payload | ConvertTo-Json -Depth 5
}

# ============================================================
# STEP 4: Apply SCIM PATCH to Update User Email
# ============================================================
function Update-ScimUserEmail {
    param(
        [object]$ScimUser,
        [string]$CurrentEmail,
        [string]$NewEmail
    )

    $UserId      = $ScimUser.id
    $UserName    = $ScimUser.userName
    $DisplayName = $ScimUser.displayName

    if ($WhatIfMode) {
        Write-Log "[WHATIF] Would update: $CurrentEmail --> $NewEmail (User: $DisplayName)" "WHATIF"
        $Stats.WhatIf++
        return
    }

    try {
        $PatchUrl = "$ScimBaseUrl/$UserId"
        $Body     = Build-ScimPatchPayload -NewEmail $NewEmail -CurrentUserName $UserName

        $Response = Invoke-RestMethod `
            -Uri     $PatchUrl `
            -Headers $Headers `
            -Method  PATCH `
            -Body    $Body

        Write-Log "Updated: $CurrentEmail --> $NewEmail (User: $DisplayName, ID: $UserId)" "SUCCESS"
        $Stats.Updated++

    } catch {
        $StatusCode = $_.Exception.Response.StatusCode.Value__
        Write-Log "Failed to update $CurrentEmail [HTTP $StatusCode]: $_" "ERROR"
        $Stats.Failed++
    }
}

# ============================================================
# STEP 5: Process Each Row in the CSV
# ============================================================
function Start-EmailUpdate {
    param([array]$UserList)

    foreach ($Row in $UserList) {
        $Stats.Total++
        $CurrentEmail = $Row.CurrentEmail.Trim()

        # --- Validate email format ---
        if (-not (Test-EmailFormat -Email $CurrentEmail)) {
            Write-Log "Invalid email format, skipping: $CurrentEmail" "SKIP"
            $Stats.Skipped++
            continue
        }

        # --- Derive new email ---
        $LocalPart = ($CurrentEmail -split "@")[0]
        $NewEmail  = "$LocalPart@$NewDomain"

        # --- Skip if already on new domain ---
        if ($CurrentEmail -like "*@$NewDomain") {
            Write-Log "Already on new domain, skipping: $CurrentEmail" "SKIP"
            $Stats.Skipped++
            continue
        }

        Write-Log "Processing ($($Stats.Total)): $CurrentEmail --> $NewEmail"

        # --- Look up user via SCIM API ---
        $ScimUser = Get-ScimUserByEmail -Email $CurrentEmail

        if ($null -eq $ScimUser) {
            $Stats.Skipped++
            continue
        }

        # --- Apply SCIM PATCH update ---
        Update-ScimUserEmail `
            -ScimUser     $ScimUser `
            -CurrentEmail $CurrentEmail `
            -NewEmail     $NewEmail

        # --- Rate limit protection ---
        Start-Sleep -Milliseconds 300
    }
}

# ============================================================
# MAIN EXECUTION
# ============================================================
Write-Log "========================================"
Write-Log " Webex Email Domain Update Script"
Write-Log " Mode: SCIM2 API + CSV Input"
Write-Log "========================================"
Write-Log "SCIM URL   : $ScimBaseUrl"
Write-Log "CSV File   : $CsvFilePath"
Write-Log "New Domain : $NewDomain"
Write-Log "WhatIf Mode: $WhatIfMode"
Write-Log "========================================"

# Load CSV
$UserList = Import-UserCsv -FilePath $CsvFilePath

# Run updates
Start-EmailUpdate -UserList $UserList

# ============================================================
# SUMMARY REPORT
# ============================================================
Write-Log "========================================"
Write-Log " SUMMARY REPORT"
Write-Log "========================================"
Write-Log "Total Processed : $($Stats.Total)"
Write-Log "Updated         : $($Stats.Updated)"
Write-Log "Skipped         : $($Stats.Skipped)"
Write-Log "Failed          : $($Stats.Failed)"
Write-Log "WhatIf Preview  : $($Stats.WhatIf)"
Write-Log "Log File        : $LogFile"
Write-Log "========================================"