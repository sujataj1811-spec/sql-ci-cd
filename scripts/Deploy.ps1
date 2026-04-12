Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server = $env:DB_SERVER
$user = $env:DB_USER
$password = $env:DB_PASSWORD
$maxParallel = 3

# PATHS
$basePath = Get-Location
$sqlPath = $sqlPath = Get-Location
$dbListFile = Join-Path $basePath "databases.txt"
$logDir = Join-Path $basePath "logs"
$tempDir = Join-Path $basePath "temp"

# Create folders
@($logDir, $tempDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ | Out-Null
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

# ================= PARALLEL EXECUTION =================
$jobs = @()

foreach ($db in $databases) {

    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $maxParallel) {
        Start-Sleep -Seconds 2
    }

    $jobs += Start-Job -ScriptBlock {

        param($database, $folders, $sqlPath, $server, $user, $password, $logDir, $tempDir)

        function Write-Log {
            param ($message, $logFile)
            $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $line = "$time - $message"
            Add-Content -Path $logFile -Value $line
        }

        $database = $database.Trim()
        $logFile = Join-Path $logDir "deployment_$database.log"

        try {
            Write-Log "===== START: $database =====" $logFile

            # Create version table
            $createTable = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SchemaVersions')
BEGIN
    CREATE TABLE SchemaVersions (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        ScriptName NVARCHAR(255),
        DatabaseName NVARCHAR(100),
        ExecutedOn DATETIME DEFAULT GETDATE(),
        Status NVARCHAR(20),
        ErrorMessage NVARCHAR(MAX)
    )
END
"@
            sqlcmd -S $server -d $database -U $user -P $password -Q $createTable

            foreach ($folder in $folders) {

                $folderPath = Join-Path $sqlPath $folder
                if (!(Test-Path $folderPath)) { continue }

                Write-Log "Processing Folder: $folder" $logFile

                $files = Get-ChildItem "$folderPath\*.sql" -ErrorAction SilentlyContinue | Sort-Object Name
                if (!$files) { continue }

                foreach ($file in $files) {

                    if (!$file.FullName) { continue }

                    $fileName = $file.Name
                    $fileSafe = $fileName.Replace("'","''")
                    $dbSafe = $database.Replace("'","''")

                    # Skip already executed
                    $checkQuery = @"
IF EXISTS (
    SELECT 1 FROM SchemaVersions 
    WHERE ScriptName = '$fileSafe' 
    AND DatabaseName = '$dbSafe'
    AND Status = 'SUCCESS'
)
SELECT 1 ELSE SELECT 0
"@

                    $result = sqlcmd -S $server -d $database -U $user -P $password -Q $checkQuery -h -1 -W | Out-String
                    if ($result.Trim() -eq "1") {
                        Write-Log "Skipping $fileName" $logFile
                        continue
                    }

                    Write-Log "Executing $fileName..." $logFile

                    # Ensure temp folder exists
                    if (!(Test-Path $tempDir)) {
                        New-Item -ItemType Directory -Path $tempDir | Out-Null
                    }

                    # Temp file
                    $tempFile = Join-Path $tempDir "$($file.BaseName).$database.$([guid]::NewGuid()).sql"

@"
USE [$database]
GO
:r "$($file.FullName)"
"@ | Out-File -Encoding utf8 $tempFile

# ================= EXECUTE =================
$startTime = Get-Date   # ⏱ Start timing

$output = sqlcmd -S $server `
                 -U $user `
                 -P $password `
                 -i "$tempFile" `
                 -b -W 2>&1 | Out-String

$endTime = Get-Date     # ⏱ End timing
$duration = ($endTime - $startTime).TotalSeconds

Write-Log "Execution Time: $duration sec" $logFile

                    # ================= CLEAN OUTPUT =================
                    $clean = $output -replace "[^\x20-\x7E\r\n]", ""
                    $lines = $clean -split "`r?`n"

                    foreach ($line in $lines) {
                        if ($line.Trim() -ne "") {
                            Write-Log $line.Trim() $logFile
                        }
                    }

                    # ================= ERROR HANDLING =================
                    if ($output -match "Msg\s+\d+, Level\s+\d+") {

                        $err = $clean.Replace("'", "''")

                        $insertFail = @"
INSERT INTO SchemaVersions (ScriptName, DatabaseName, ExecutedOn, Status, ErrorMessage)
VALUES ('$fileSafe', '$dbSafe', GETDATE(), 'FAILED', '$err')
"@

                        sqlcmd -S $server -d $database -U $user -P $password -Q $insertFail

                        throw "Error executing $fileName"
                    }

                    # ================= SUCCESS =================
                    $insertSuccess = @"
INSERT INTO SchemaVersions (ScriptName, DatabaseName, ExecutedOn, Status)
VALUES ('$fileSafe', '$dbSafe', GETDATE(), 'SUCCESS')
"@

                    sqlcmd -S $server -d $database -U $user -P $password -Q $insertSuccess

                    Write-Log "Completed $fileName ✅" $logFile
                }
            }

            Write-Log "===== SUCCESS: $database =====" $logFile
        }
        catch {
            Write-Log "===== FAILED: $database =====" $logFile
            Write-Log "Error: $($_.Exception.Message)" $logFile
            throw
        }

    } -ArgumentList $db, $folders, $sqlPath, $server, $user, $password, $logDir, $tempDir
}

# ================= WAIT =================
foreach ($job in $jobs) {
    Wait-Job $job
    Receive-Job $job -ErrorAction Continue
}

# ================= FINAL STATUS =================
$failed = $jobs | Where-Object { $_.State -ne "Completed" }

if ($failed.Count -gt 0) {
    Write-Output "❌ Deployment FAILED"
    exit 1
}
else {
    Write-Output "✅ Deployment SUCCESS"
}