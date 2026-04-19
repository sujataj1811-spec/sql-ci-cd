Write-Output "===== SQL Flyway Engine STARTED ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$basePath      = Get-Location
$migrationPath = Join-Path $basePath "migrations"
$logDir        = "C:\ESD\sql-ci-cd\logs"

$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD

# ================= SAFE INIT =================
if (!(Test-Path $migrationPath)) {
    Write-Host "⚠ migrations folder missing. Creating..."
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# ================= LOG =================
function Write-Log {
    param($msg)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$time - $msg"
    Write-Output $line
    Add-Content -Path $logFile -Value $line
}

# ================= GET FILES SAFELY =================
function Get-SafeFiles($pattern) {
    if (Test-Path $migrationPath) {
        return Get-ChildItem "$migrationPath\$pattern" -ErrorAction SilentlyContinue
    }
    return @()
}


# ===== ENTERPRISE ORDER FIX =====
$orderedGroups = @(
    "V1","V2","V3","V4","V5","V6","V7","V8","V9","V10","V11","V12"
)

# ✅ ADD THIS RIGHT HERE 👇
$migrationsV = @()

foreach ($prefix in $orderedGroups) {
    $files = Get-SafeFiles "$prefix*.sql"
    $migrationsV += $files
}



# ================= LOAD VERSIONED FILES IN ORDER =================
$migrationsV = foreach ($prefix in $orderedGroups) {
    Get-SafeFiles "$prefix*.sql"
}

# ================= DB LIST =================
$dbListFile = Join-Path $basePath "scripts\databases.txt"

if (!(Test-Path $dbListFile)) {
    throw "databases.txt not found!"
}

$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

# ================= RUN SCRIPT =================
function Run-Script {
    param($file, $db)

    $fileName = $file.Name

if ($fileName -match "^V(\d+)__(.+)\.sql$") {
    $version = $matches[1]
    $desc = $matches[2].Replace("_"," ")
}
    elseif ($fileName -match "^R__(.+)\.sql$") {
        $version = "R"
        $desc = $matches[1].Replace("_"," ")
    }
    else {
        Write-Log "Skipping invalid file: $fileName"
        return
    }

    $checksum = (Get-FileHash $file.FullName).Hash

    Write-Log "Checking: $fileName"

    # skip only versioned
    if ($version -ne "R") {
        $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM FlywaySchemaHistory WHERE Version = '$version' AND Success = 1)
SELECT 1 ELSE SELECT 0
"@

        $exists = sqlcmd -S $server -d $db -U $user -P $password -Q $checkQuery -h -1 -W | Out-String

        if (($exists -replace "[^0-9]","") -eq "1") {
            Write-Log "Skipping already applied: $fileName"
            return
        }
    }

    Write-Log "Executing: $fileName"

    $start = Get-Date
    $success = 1
    $output = ""

    try {
        $output = Invoke-Sqlcmd `
            -ServerInstance $server `
            -Database $db `
            -Username $user `
            -Password $password `
            -InputFile $file.FullName `
            -ErrorAction Stop | Out-String
    }
    catch {
        $output = $_.Exception.Message
        $success = 0
    }

    $duration = ((Get-Date) - $start).TotalSeconds
    Write-Log $output

    # history insert
    $insert = @"
INSERT INTO FlywaySchemaHistory
(Version, Description, ScriptName, Checksum, InstalledBy, ExecutionTime, Success)
VALUES
('$version','$desc','$fileName','$checksum','$env:USERNAME',$duration,$success)
"@

    sqlcmd -S $server -d $db -U $user -P $password -Q $insert

    if ($success -eq 0) {
        Write-Log "FAILED: $fileName"
        throw "Migration failed. Stopping execution."
    }

    Write-Log "SUCCESS: $fileName ($duration sec)"
}

# ================= MAIN EXECUTION =================
foreach ($file in $migrationsV)
foreach ($db in $databases) {

    Write-Log "===== START DB: $db ====="

    foreach ($file in $migrationsV) {
        Run-Script $file $db
    }

   } 
{

    $timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logFile = Join-Path $logDir "flyway_${db}_$timeStamp.log"

    Write-Log "===== START DB: $db ====="

    # ensure history table
    $historyTable = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'FlywaySchemaHistory')
BEGIN
    CREATE TABLE FlywaySchemaHistory (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        Version NVARCHAR(50),
        Description NVARCHAR(255),
        ScriptName NVARCHAR(255),
        Checksum NVARCHAR(64),
        InstalledBy NVARCHAR(100),
        InstalledOn DATETIME DEFAULT GETDATE(),
        ExecutionTime FLOAT,
        Success BIT
    )
END
"@

    sqlcmd -S $server -d $db -U $user -P $password -Q $historyTable

    # RUN VERSIONED FIRST
    foreach ($file in $migrationsV) {
        Run-Script $file $db
    }


    Write-Log "===== END DB: $db ====="
}

Write-Output "===== SQL Flyway Engine COMPLETED SUCCESSFULLY ====="