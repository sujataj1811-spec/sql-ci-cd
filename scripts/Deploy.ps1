Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD

Write-Host "SERVER=$server"
Write-Host "USER=$user"

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath   # IMPORTANT FIX (no sql-ci-cd folder)
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = Join-Path $basePath "logs"
$tempDir    = Join-Path $basePath "temp"

# Create folders
@($logDir, $tempDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ | Out-Null
    }
}
Write-Host "Running file: $($file.FullName)"
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
foreach ($database in $databases) {

    $database = $database.Trim()
    $logFile  = Join-Path $logDir "deployment_$database.log"

    function Write-Log {
        param ($msg)
        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$time - $msg"
    }

    try {
        Write-Log "===== START: $database ====="

        # Test connection
        sqlcmd -S $server -U $user -P $password -Q "SELECT 1" | Out-Null
        Write-Log "Connection SUCCESS"

        foreach ($folder in $folders) {

            $folderPath = Join-Path $sqlPath $folder
            if (!(Test-Path $folderPath)) { continue }

            Write-Log "Processing Folder: $folder"

            $files = Get-ChildItem "$folderPath\*.sql" -ErrorAction SilentlyContinue | Sort-Object Name

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

                Write-Log $output

                # ✅ ONLY FAIL IF REAL SQL ERROR
              if ($output -match "Msg\s+\d+") {
    Write-Host "===== SQL ERROR OUTPUT ====="
    Write-Host $output
    throw "SQL execution failed"
}

                Write-Log "✅ Completed: $($file.Name)"
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