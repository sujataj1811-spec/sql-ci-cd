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

# ================= GET FILES =================
function Get-SafeFiles($pattern) {
    if (Test-Path $migrationPath) {
        return Get-ChildItem "$migrationPath\$pattern" -ErrorAction SilentlyContinue
    }
    return @()
}


# ================= DEPENDENCY ENGINE v3 =================

Write-Output "===== BUILDING EXECUTION ORDER USING DEPENDENCY ENGINE ====="

$order = & "$env:GITHUB_WORKSPACE\scripts\Build-Dependency-Engine-V3.ps1"

$migrationsV = Get-Content ".\execution-order.txt" |
    ForEach-Object {
        $migrationsV = Get-Content ".\execution-order.txt" |
ForEach-Object {
    $path = Join-Path $migrationPath $_

    if (Test-Path $path) {
        Get-Item $path
    }
    else {
        Write-Host "⚠ Missing file skipped: $_"
    }
} | Where-Object { $_ -ne $null }
    }

Write-Output "===== ORDER RESOLVED: $($migrationsV.Count) FILES ====="

# FINAL SAFETY SORT (IMPORTANT)
$migrationsV = $migrationsV | Sort-Object {
    if ($_.Name -match "^V(\d+)__") {
        [int]$matches[1]
    } else {
        999999
    }
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

    # skip already executed
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
foreach ($db in $databases) {

    $timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logFile = Join-Path $logDir "flyway_${db}_$timeStamp.log"

    Write-Log "===== START DB: $db ====="

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

    # ================= ORDERED EXECUTION (FIX APPLIED HERE) =================
    foreach ($file in $migrationsV) {
        Run-Script $file $db
    }

    Write-Log "===== END DB: $db ====="
}

Write-Output "===== SQL Flyway Engine COMPLETED SUCCESSFULLY ====="