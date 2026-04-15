Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = Join-Path $basePath "logs"
$tempDir    = Join-Path $basePath "temp"

Write-Host "Using Log Directory: $logDir"

# Ensure folders exist
@($logDir, $tempDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# ================= VALIDATION =================
if (!(Test-Path $dbListFile)) { throw "databases.txt not found!" }
$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

# ================= FOLDER ORDER =================
$folders = @(
    "01_Tables","02_Views","03_Procedures",
    "04_Functions","05_Triggers","06_Indexes","07_Data"
)

# ================= MAIN =================
foreach ($database in $databases) {

    $database = $database.Trim()
    if ([string]::IsNullOrWhiteSpace($database)) { continue }

    $logFile = Join-Path $logDir "deployment_$database.log"

    if (!(Test-Path $logFile)) {
        New-Item -ItemType File -Path $logFile -Force | Out-Null
    }

    function Write-Log {
        param ($msg)
        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$time - $msg"
    }

    Write-Log "===== START: $database ====="

    try {

        # ================= ENSURE TABLE =================
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

        foreach ($folder in $folders) {

            $folderPath = Join-Path $sqlPath $folder
            if (!(Test-Path $folderPath)) { continue }

            Write-Log "Processing Folder: $folder"

            $files = Get-ChildItem "$folderPath\*.sql" | Sort-Object Name

            foreach ($file in $files) {

                if (!(Test-Path $file.FullName)) {
                    Write-Log "FILE NOT FOUND: $($file.FullName)"
                    continue
                }

                $fileName   = $file.Name
                $fileSafe   = $fileName.Replace("'","''")
                $dbSafe     = $database.Replace("'","''")
                $scriptHash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

                Write-Log "Executing: $fileName"

                # ================= VALIDATION =================
                $content = Get-Content $file.FullName -Raw
                $clean   = $content -replace '--.*', '' -replace '/\*[\s\S]*?\*/', ''
                $sql     = $clean.ToUpper()

                if ($sql.Contains("DROP DATABASE")) { Write-Log "BLOCKED: DROP DATABASE"; continue }
                if ($sql.Contains("TRUNCATE TABLE")) { Write-Log "BLOCKED: TRUNCATE TABLE"; continue }
                if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) { Write-Log "BLOCKED: DELETE without WHERE"; continue }

                # ================= SKIP =================
                $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (
    SELECT 1 FROM SchemaVersions 
    WHERE ScriptName = '$fileSafe'
    AND DatabaseName = '$dbSafe'
    AND ScriptHash = '$scriptHash'
    AND Status = 'SUCCESS'
)
SELECT 1 ELSE SELECT 0
"@

                $check = sqlcmd -S $server -d $database -U $user -P $password -Q $checkQuery -h -1 -W | Out-String
                $cleanCheck = $check -replace "[^0-9]", ""

                if ($cleanCheck -eq "1") {
                    Write-Log "SKIPPED: $fileName"
                    continue
                }

                # ================= TEMP FILE =================
                $tempFile = Join-Path $tempDir "$($file.BaseName)_$database.sql"

@"
USE [$database]
GO
:r "$($file.FullName)"
GO
"@ | Set-Content -Path $tempFile -Encoding UTF8

                if (!(Test-Path $tempFile)) {
                    throw "Temp file not created"
                }

                # ================= EXECUTION =================
                $start = Get-Date

                $output = sqlcmd -S $server `
                                 -d $database `
                                 -U $user `
                                 -P $password `
                                 -i "$tempFile" `
                                 -W -h -1 2>&1 | Out-String

                $end = Get-Date
                $duration = ($end - $start).TotalSeconds

                Write-Log "OUTPUT:"
                $cleanOutput = $output -replace "sqlcmd :.*","" `
                                       -replace "At line:.*","" `
                                       -replace "\+.*",""
                $cleanOutput = $cleanOutput.Trim()

                if ($cleanOutput) { Write-Log $cleanOutput }

                # ================= ERROR =================
                if ($output -match "Msg\s+\d+") {

                    Write-Log "ERROR DETECTED"

                    $safeOutput = $output.Replace("'", "''")

                    sqlcmd -S $server -d $database -U $user -P $password `
                        -Q "INSERT INTO SchemaVersions 
                            (ScriptName,DatabaseName,ScriptHash,Status,ErrorMessage,ExecutionTime)
                            VALUES ('$fileSafe','$dbSafe','$scriptHash','FAILED','$safeOutput',$duration)"

                    throw "SQL FAILED: $fileName"
                }

                # ================= SUCCESS =================
                sqlcmd -S $server -d $database -U $user -P $password `
                    -Q "INSERT INTO SchemaVersions 
                        (ScriptName,DatabaseName,ScriptHash,Status,ExecutionTime)
                        VALUES ('$fileSafe','$dbSafe','$scriptHash','SUCCESS',$duration)"

                Write-Log "SUCCESS: $fileName ($duration sec)"
            }
        }

        Write-Log "===== SUCCESS: $database ====="
    }
    catch {
        Write-Log "===== FAILED: $database ====="
        Write-Log $_.Exception.Message
        throw
    }
}

Write-Output "===== Deployment Completed ====="