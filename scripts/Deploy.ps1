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
$timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logDir "flyway_${database}_$timeStamp.log"

foreach ($database in $databases) {

    # 🔥 Create separate log per DB
    $logFile = Join-Path $logDir "flyway_$database.log"

    Write-Log "===== Deploying to Database: $database ====="

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

# ================= DATABASE LIST =================
$dbListFile = Join-Path $basePath "scripts\databases.txt"

if (!(Test-Path $dbListFile)) {
    throw "databases.txt not found!"
}

$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

# ================= GET MIGRATIONS =================
$migrations = Get-ChildItem "$migrationPath\V*.sql" | Sort-Object Name

foreach ($database in $databases) {

    Write-Log "===== Deploying to Database: $database ====="

    # ✅ Create history table INSIDE each DB
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

    sqlcmd -S $server -d $database -U $user -P $password -Q $historyTable

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

        # ================= CHECK ALREADY EXECUTED =================
        $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (
    SELECT 1 FROM FlywaySchemaHistory
    WHERE Version = '$version' AND Success = 1
)
SELECT 1 ELSE SELECT 0
"@

        $exists = sqlcmd -S $server -d $database -U $user -P $password -Q $checkQuery -h -1 -W | Out-String

        if (($exists -replace "[^0-9]","") -eq "1") {
            Write-Log "Skipping (already applied): $fileName"
            continue
        }

        Write-Log "Executing: $fileName"
        Write-Host "Running on DB: $database"

        $start = Get-Date
        $output = ""
        $success = 1

        try {
            $output = Invoke-Sqlcmd `
                -ServerInstance $server `
                -Database $database `
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

        $safeOutput = $output.Replace("'", "''")

        # ================= INSERT HISTORY =================
        $insertQuery = @"
INSERT INTO FlywaySchemaHistory
(Version, Description, ScriptName, Checksum, InstalledBy, ExecutionTime, Success)
VALUES
('$version', '$desc', '$fileName', '$checksum', '$env:USERNAME', $duration, $success)
"@

        sqlcmd -S $server -d $database -U $user -P $password -Q $insertQuery

        if ($success -eq 0) {
            Write-Log "FAILED: $fileName"
            throw "Migration failed. Stopping execution."
        }

        Write-Log "SUCCESS: $fileName ($duration sec)"
    }
}

Write-Output "===== Deployment Completed Successfully ====="