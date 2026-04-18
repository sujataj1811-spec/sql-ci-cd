Write-Output "===== Flyway-Style SQL Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD

$basePath      = Get-Location
$migrationPath = Join-Path $basePath "migrations"
$logDir        = "C:\ESD\sql-ci-cd\logs"

if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$logFile = Join-Path $logDir "flyway_deployment.log"

function Write-Log {
    param ($msg)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$time - $msg"
    Write-Output $line
    Add-Content -Path $logFile -Value $line
}

# ================= VALIDATION =================
if (!(Test-Path $migrationPath)) {
    throw "Migrations folder not found!"
}

# ================= CREATE HISTORY TABLE =================
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

sqlcmd -S $server -U $user -P $password -Q $historyTable

# ================= GET MIGRATIONS =================
$migrations = Get-ChildItem "$migrationPath\V*.sql" | Sort-Object Name

foreach ($file in $migrations) {

    $fileName = $file.Name

    # Parse version and description
    if ($fileName -match "^V(\d+)__(.+)\.sql$") {
        $version = $matches[1]
        $desc    = $matches[2].Replace("_"," ")
    }
    else {
        Write-Log "Skipping invalid file: $fileName"
        continue
    }

    $checksum = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

    Write-Log "Checking: $fileName"

    # Check already executed
    $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (
    SELECT 1 FROM FlywaySchemaHistory
    WHERE Version = '$version' AND Success = 1
)
SELECT 1 ELSE SELECT 0
"@

    $exists = sqlcmd -S $server -U $user -P $password -Q $checkQuery -h -1 -W | Out-String

    if (($exists -replace "[^0-9]","") -eq "1") {
        Write-Log "Skipping (already applied): $fileName"
        continue
    }

    Write-Log "Executing: $fileName"

    $start = Get-Date

    try {
        $output = sqlcmd -S $server -U $user -P $password -i $file.FullName -b 2>&1 | Out-String
        $success = 1
    }
    catch {
        $output = $_.Exception.Message
        $success = 0
    }

    $duration = ((Get-Date) - $start).TotalSeconds

    Write-Log $output

    $safeOutput = $output.Replace("'", "''")

    $insertQuery = @"
INSERT INTO FlywaySchemaHistory
(Version, Description, ScriptName, Checksum, InstalledBy, ExecutionTime, Success)
VALUES
('$version', '$desc', '$fileName', '$checksum', '$env:USERNAME', $duration, $success)
"@

    sqlcmd -S $server -U $user -P $password -Q $insertQuery

    if ($success -eq 0) {
        Write-Log "FAILED: $fileName"
        throw "Migration failed. Stopping execution."
    }

    Write-Log "SUCCESS: $fileName ($duration sec)"
}

Write-Output "===== Deployment Completed Successfully ====="