Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD
$maxParallel = 3

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = Join-Path $basePath "logs"

# Ensure log folder
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-Host "Using Log Directory: $logDir"

# ================= DATABASE LIST =================
if (!(Test-Path $dbListFile)) { throw "databases.txt not found!" }
$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

# ================= PARALLEL EXECUTION =================
$jobs = @()

foreach ($db in $databases) {

    while ($jobs.Count -ge $maxParallel) {
        $jobs = $jobs | Where-Object { $_.State -eq "Running" }
        Start-Sleep -Seconds 2
    }

    $jobs += Start-Job -ScriptBlock {

        param($database, $server, $user, $password, $sqlPath, $logDir)

        # ================= LOG =================
        $logFile = Join-Path $logDir "deployment_$database.log"

        function Write-Log {
            param ($msg)
            $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            "$time - $msg" | Out-File -FilePath $logFile -Append -Encoding utf8
        }

        # ================= VALIDATION =================
        function Validate-SqlScript {
            param ($filePath)

            $content = Get-Content $filePath -Raw
            $contentClean = $content -replace '--.*', '' -replace '/\*[\s\S]*?\*/', ''
            $sql = $contentClean.ToUpper()

            if ($sql.Contains("DROP DATABASE")) {
                Write-Log "BLOCKED: DROP DATABASE in $filePath"
                return $false
            }

            if ($sql.Contains("TRUNCATE TABLE")) {
                Write-Log "BLOCKED: TRUNCATE TABLE in $filePath"
                return $false
            }

            if ($sql.Contains("DROP TABLE")) {
                Write-Log "WARNING: DROP TABLE in $filePath"
            }

            if ($sql.Contains("ALTER TABLE") -and $sql.Contains("DROP COLUMN")) {
                Write-Log "WARNING: DROP COLUMN in $filePath"
            }

            if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) {
                Write-Log "BLOCKED: DELETE without WHERE in $filePath"
                return $false
            }

            if ($sql.Contains("UPDATE") -and -not ($sql.Contains("WHERE"))) {
                Write-Log "WARNING: UPDATE without WHERE in $filePath"
            }

            return $true
        }

        # ================= START =================
        Write-Log "===== START: $database ====="

        # Ensure SchemaVersions
        $createTable = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SchemaVersions')
BEGIN
    CREATE TABLE SchemaVersions (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        ScriptName NVARCHAR(255),
        DatabaseName NVARCHAR(100),
        Status NVARCHAR(20),
        ExecutedOn DATETIME DEFAULT GETDATE()
    )
END
"@

        sqlcmd -S $server -d $database -U $user -P $password -Q $createTable

        $phases = @(
            "01_Tables","02_Views","03_Procedures",
            "04_Functions","05_Triggers","06_Indexes","07_Data"
        )

        $failedScripts = @()

        foreach ($phase in $phases) {

            $folderPath = Join-Path $sqlPath $phase
            if (!(Test-Path $folderPath)) { continue }

            Write-Log "Processing Folder: $phase"

            $files = Get-ChildItem "$folderPath\*.sql" | Sort-Object Name

            foreach ($file in $files) {

                $fileName = $file.Name

                Write-Log "VALIDATING: $fileName"

                if (-not (Validate-SqlScript $file.FullName)) {
                    Write-Log "SKIPPED (Validation Failed): $fileName"
                    continue
                }

                # ================= SKIP =================
                $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (
    SELECT 1 FROM SchemaVersions
    WHERE ScriptName = '$fileName'
    AND DatabaseName = '$database'
    AND Status = 'SUCCESS'
)
SELECT 1 ELSE SELECT 0
"@

                $check = sqlcmd -S $server -d $database -U $user -P $password `
                    -Q $checkQuery -h -1 -W | Out-String

                if ($check.Trim() -eq "1") {
                    Write-Log "SKIPPING (already deployed): $fileName"
                    continue
                }

                # ================= EXECUTION =================
                Write-Log "Executing $fileName..."

                $start = Get-Date

                $output = sqlcmd -S $server -d $database -U $user -P $password `
                    -i "$($file.FullName)" -b 2>&1 | Out-String

                $duration = ((Get-Date) - $start).TotalSeconds

                # Clean output
                $cleanOutput = $output -replace "sqlcmd :.*", "" `
                                       -replace "At line:.*", "" `
                                       -replace "CategoryInfo.*", "" `
                                       -replace "FullyQualifiedErrorId.*", ""

                if ($cleanOutput.Trim()) {
                    Write-Log $cleanOutput.Trim()
                }

                # ================= ERROR =================
                if ($output -match "Msg\s+\d+") {

                    Write-Log "ERROR: $fileName"

                    $safeOutput = $output.Replace("'", "''")

                    sqlcmd -S $server -d $database -U $user -P $password `
                        -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,Status,ErrorMessage)
                            VALUES ('$fileName','$database','FAILED','$safeOutput')"

                    $failedScripts += $file
                    continue
                }

                # ================= SUCCESS =================
                sqlcmd -S $server -d $database -U $user -P $password `
                    -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,Status)
                        VALUES ('$fileName','$database','SUCCESS')"

                Write-Log "$fileName executed in $duration sec"
            }
        }

        # ================= RETRY =================
        if ($failedScripts.Count -gt 0) {

            Write-Log "===== RETRY FAILED SCRIPTS ====="

            foreach ($file in $failedScripts) {

                Write-Log "Retrying: $($file.Name)"

                $output = sqlcmd -S $server -d $database -U $user -P $password `
                    -i "$($file.FullName)" -b 2>&1 | Out-String

                if ($output -match "Msg\s+\d+") {
                    Write-Log "FINAL FAIL: $($file.Name)"
                    throw "Deployment failed in $database"
                }

                Write-Log "RECOVERED: $($file.Name)"
            }
        }

        Write-Log "===== SUCCESS: $database ====="

    } -ArgumentList $db, $server, $user, $password, $sqlPath, $logDir
}

# Wait for all jobs
$jobs | Wait-Job | Receive-Job

Write-Output "===== Deployment Completed ====="