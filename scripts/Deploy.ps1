Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server      = $env:DB_SERVER
$user        = $env:DB_USER
$password    = $env:DB_PASSWORD
$maxParallel = 3

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = "C:\ESD\sql-ci-cd\logs"
$tempDir    = Join-Path $basePath "temp"

Write-Host "Using Log Directory: $logDir"

# Ensure folders
@($logDir, $tempDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# ================= VALIDATION FUNCTION =================
function Validate-SqlScript {
    param ($filePath, $logFile)

    $content = Get-Content $filePath -Raw
    $contentClean = $content -replace '--.*', '' -replace '/\*[\s\S]*?\*/', ''
    $sql = $contentClean.ToUpper()

    if ($sql.Contains("DROP DATABASE")) {
        Add-Content $logFile "$(Get-Date) - BLOCKED: DROP DATABASE in $filePath"
        return $false
    }

    if ($sql.Contains("TRUNCATE TABLE")) {
        Add-Content $logFile "$(Get-Date) - BLOCKED: TRUNCATE TABLE in $filePath"
        return $false
    }

    if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) {
        Add-Content $logFile "$(Get-Date) - BLOCKED: DELETE without WHERE"
        return $false
    }

    if ($sql.Contains("UPDATE") -and -not ($sql.Contains("WHERE"))) {
        Add-Content $logFile "$(Get-Date) - WARNING: UPDATE without WHERE"
    }

    if ($sql.Contains("DROP TABLE")) {
        Add-Content $logFile "$(Get-Date) - WARNING: DROP TABLE in $filePath"
    }

    if ($sql.Contains("ALTER TABLE") -and $sql.Contains("DROP COLUMN")) {
        Add-Content $logFile "$(Get-Date) - WARNING: DROP COLUMN in $filePath"
    }

    return $true
}

# ================= DB LIST =================
if (!(Test-Path $dbListFile)) {
    throw "databases.txt not found!"
}

$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

# ================= DEPLOY SCRIPT =================
$deployScript = {

    param ($database, $server, $user, $password, $sqlPath, $logDir, $tempDir)

    $database = $database.Trim()
    if ([string]::IsNullOrWhiteSpace($database)) { return }

    $logFile = Join-Path $logDir "deployment_$database.log"

    if (!(Test-Path $logFile)) {
        New-Item -ItemType File -Path $logFile | Out-Null
    }

    function Write-Log {
        param ($msg)
        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$time - $msg"
    }

    Write-Log "===== START: $database ====="

    # ================= CREATE TRACKING TABLE =================
    $createTable = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SchemaVersions')
BEGIN
    CREATE TABLE SchemaVersions (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        ScriptName NVARCHAR(255),
        DatabaseName NVARCHAR(100),
        ScriptHash NVARCHAR(64),
        Status NVARCHAR(20),
        ErrorMessage NVARCHAR(MAX),
        ExecutionTime FLOAT,
        ExecutedOn DATETIME DEFAULT GETDATE()
    )
END
"@

    sqlcmd -S $server -d $database -U $user -P $password -Q $createTable

    # ================= EXECUTION ORDER =================
    $folders = @(
        "01_Tables",
        "02_Views",
        "03_Procedures",
        "04_Functions",
        "05_Triggers",
        "06_Indexes",
        "07_Data"
    )

    foreach ($folder in $folders) {

        $folderPath = Join-Path $sqlPath $folder
        if (!(Test-Path $folderPath)) { continue }

        Write-Log "Processing Folder: $folder"

        $files = Get-ChildItem "$folderPath\*.sql" | Sort-Object Name

        foreach ($file in $files) {

            $fileName   = $file.Name
            $fileSafe   = $fileName.Replace("'","''")
            $dbSafe     = $database.Replace("'","''")
            $scriptHash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

            Write-Log "Executing $fileName..."

            # ================= VALIDATION =================
            $content = Get-Content $file.FullName -Raw
$contentClean = $content -replace '--.*', '' -replace '/\*[\s\S]*?\*/', ''
$sql = $contentClean.ToUpper()

if ($sql.Contains("DROP DATABASE") -or $sql.Contains("TRUNCATE TABLE")) {
    Write-Log "BLOCKED SCRIPT: $fileName"
    continue
} {
                throw "Validation failed: $fileName"
            }

            # ================= SKIP CHECK =================
            $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (
 SELECT 1 FROM SchemaVersions
 WHERE ScriptName='$fileSafe'
 AND DatabaseName='$dbSafe'
 AND ScriptHash='$scriptHash'
 AND Status='SUCCESS'
)
SELECT 1 ELSE SELECT 0
"@

            $check = sqlcmd -S $server -d $database -U $user -P $password -Q $checkQuery -h -1 -W | Out-String

            if (($check -replace "[^0-9]","") -eq "1") {
                Write-Log "SKIPPING (already deployed): $fileName"
                continue
            }

            # ================= EXECUTION =================
            $start = Get-Date

            $sqlContent = Get-Content $file.FullName -Raw
            $tempFile = Join-Path $tempDir "$($file.BaseName)_$database.sql"

            $sqlWrapper = @"
USE [$database];
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRAN;

$sqlContent

    COMMIT TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    THROW;
END CATCH
"@

            $sqlWrapper | Out-File -Encoding utf8 $tempFile

            $output = sqlcmd -S $server -U $user -P $password -i $tempFile -b 2>&1 | Out-String
            $duration = ((Get-Date) - $start).TotalSeconds

            Write-Log $output

            # ================= ERROR CHECK =================
            if ($LASTEXITCODE -ne 0) {

                Write-Log "ERROR: $output"
                $safeOutput = $output.Replace("'", "''")

                sqlcmd -S $server -d $database -U $user -P $password `
                -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,ScriptHash,Status,ErrorMessage,ExecutionTime)
                    VALUES ('$fileSafe','$dbSafe','$scriptHash','FAILED','$safeOutput',$duration)"

                throw "SQL FAILED: $fileName"
            }

            # ================= SUCCESS =================
            sqlcmd -S $server -d $database -U $user -P $password `
            -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,ScriptHash,Status,ExecutionTime)
                VALUES ('$fileSafe','$dbSafe','$scriptHash','SUCCESS',$duration)"

            Write-Log "$fileName executed in $duration sec"
        }
    }

    Write-Log "===== SUCCESS: $database ====="
}

# ================= PARALLEL EXECUTION =================
$jobs = @()

foreach ($db in $databases) {

    while ($jobs.Count -ge $maxParallel) {
        $jobs = $jobs | Where-Object { $_.State -eq "Running" }
        Start-Sleep 2
    }

    $job = Start-Job -ScriptBlock $deployScript `
        -ArgumentList $db, $server, $user, $password, $sqlPath, $logDir, $tempDir

    $jobs += $job
}

$jobs | Wait-Job | Receive-Job

Write-Output "===== Deployment Completed ====="