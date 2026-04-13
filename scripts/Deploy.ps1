Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD

if (-not $server -or -not $user -or -not $password) {
    throw "Database credentials not set in GitHub Secrets!"
}

Write-Host "SERVER=$server"
Write-Host "USER=$user"

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath   # SQL folders are in root
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = Join-Path $basePath "logs"
$tempDir    = Join-Path $basePath "temp"

# Create folders
@($logDir, $tempDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ | Out-Null
    }
}

# ================= VALIDATION =================
if (!(Test-Path $dbListFile)) {
    throw "databases.txt not found!"
}

$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

# ================= FOLDER ORDER =================
$folders = @(
    "01_Tables","02_Views","03_Procedures",
    "04_Functions","05_Triggers","06_Indexes","07_Data"
)

# ================= MAIN =================
foreach ($db in $databases) {

    $database = $db.Trim()
    $logFile  = Join-Path $logDir "deployment_$database.log"

    function Write-Log {
        param ($msg)
        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "$time - $msg"
        Add-Content -Path $logFile -Value $line
        Write-Host $line
    }

    try {
        Write-Log "===== START: $database ====="

        # 🔥 TEST CONNECTION (FAIL FAST)
        sqlcmd -S $server -U $user -P $password -Q "SELECT GETDATE()" | Out-Null
        Write-Log "Connection SUCCESS"

        foreach ($folder in $folders) {

            $folderPath = Join-Path $sqlPath $folder

            if (!(Test-Path $folderPath)) {
                Write-Log "Skipping (not found): $folder"
                continue
            }

            Write-Log "Processing Folder: $folder"

            $files = Get-ChildItem "$folderPath\*.sql" -ErrorAction SilentlyContinue | Sort-Object Name

            if (!$files) {
                Write-Log "No SQL files in $folder"
                continue
            }

            foreach ($file in $files) {

                Write-Log "Executing: $($file.Name)"

                $tempFile = Join-Path $tempDir "$($file.BaseName)_$database.sql"

@"
USE [$database]
GO
:r "$($file.FullName)"
"@ | Out-File -Encoding utf8 $tempFile

$output = sqlcmd -S $server `
                 -U $user `
                 -P $password `
                 -i "$tempFile" `
                 2>&1 | Out-String

# Clean output
$clean = $output -replace "[^\x20-\x7E\r\n]", ""

Write-Log $clean

# ✅ REAL ERROR CHECK (PUT HERE)
if ($output -match "Msg\s+\d+") {
    Write-Log "❌ SQL ERROR in $($file.Name)"
    throw "SQL Error detected in $($file.Name)"
}

Write-Log "Completed: $($file.Name)"

        Write-Log "===== SUCCESS: $database ====="
    }
    catch {
        Write-Log "===== FAILED: $database ====="
        Write-Log $_.Exception.Message
        throw
    }
}

Write-Output "===== Deployment Completed ====="