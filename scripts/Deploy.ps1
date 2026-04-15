Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server   = $env:DB_SERVER
$user     = $env:DB_USER
$password = $env:DB_PASSWORD

# ================= EMAIL CONFIG =================
$smtpServer   = "smtp.gmail.com"
$smtpPort     = 587
$emailFrom    = "your_email@gmail.com"
$emailTo      = "your_email@gmail.com"
$emailPassword= "your_app_password"


# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = Join-Path $basePath "logs"
$tempDir    = Join-Path $basePath "temp"

# ✅ DEBUG (add here)
Write-Host "Using Log Directory: $logDir"

# ✅ ENSURE log folder exists (add here)
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Create folders
@($logDir, $tempDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ | Out-Null
    }
}

# ================= EMAIL FUNCTION =================
function Send-Email {
    param ($subject, $body)
    try {
        $securePassword = ConvertTo-SecureString $emailPassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($emailFrom, $securePassword)

        Send-MailMessage `
            -From $emailFrom `
            -To $emailTo `
            -Subject $subject `
            -Body $body `
            -SmtpServer $smtpServer `
            -Port $smtpPort `
            -UseSsl `
            -Credential $cred
    }
    catch {
        Write-Host "Email sending failed"
    }
}

# ================= VALIDATION FUNCTION =================
function Validate-SqlScript {
    param ($filePath, $logFile)

    $content = Get-Content $filePath -Raw
    $contentClean = $content -replace '--.*', '' -replace '/\*[\s\S]*?\*/', ''
    $sql = $contentClean.ToUpper()

    if ($sql.Contains("DROP DATABASE")) { Add-Content $logFile "BLOCKED: DROP DATABASE in $filePath"; return $false }
    if ($sql.Contains("TRUNCATE TABLE")) { Add-Content $logFile "BLOCKED: TRUNCATE TABLE in $filePath"; return $false }
    if ($sql.Contains("DROP TABLE")) { Add-Content $logFile "WARNING: DROP TABLE in $filePath" }
    if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) { Add-Content $logFile "BLOCKED: DELETE without WHERE"; return $false }
    if ($sql.Contains("UPDATE") -and -not ($sql.Contains("WHERE"))) { Add-Content $logFile "WARNING: UPDATE without WHERE" }

    return $true
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
    Write-Host "Log file path: $logFile"

    if (!(Test-Path $logFile)) {
        New-Item -ItemType File -Path $logFile -Force | Out-Null
    }

    function Write-Log {
        param ($msg)
        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$time - $msg"
    }

    try {
        Write-Log "===== START: $database ====="
Write-Log "Log initialized"
        # Ensure SchemaVersions table exists
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
ELSE
BEGIN
    IF COL_LENGTH('SchemaVersions','ScriptHash') IS NULL
        ALTER TABLE SchemaVersions ADD ScriptHash NVARCHAR(64)
END
"@

        sqlcmd -S $server -d $database -U $user -P $password -Q $createTable

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

                Write-Log "Executing: $fileName"

                if (-not (Validate-SqlScript $file.FullName $logFile)) {
                    throw "Validation failed for $fileName"
                }

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

                $check = sqlcmd -S $server -d $database -U $user -P $password `
                    -Q $checkQuery -h -1 -W | Out-String

                $cleanCheck = $check -replace "[^0-9]", ""

                if ($cleanCheck -eq "1") {
                    Write-Log "SKIPPED: $fileName (No changes)"
                    continue
                }


$start = Get-Date

$output = sqlcmd -S $server `
                 -U $user `
                 -P $password `
                 -i "$tempFile" `
                 -W -h -1 2>&1 | Out-String

$duration = ((Get-Date) - $start).TotalSeconds


Write-Log "OUTPUT:"
$cleanOutput = $output -replace "sqlcmd :.*", "" `
                       -replace "At line:.*", "" `
                       -replace "\+.*", "" `
                       -replace "CategoryInfo.*", "" `
                       -replace "FullyQualifiedErrorId.*", ""

$cleanOutput = $cleanOutput.Trim()

if ($cleanOutput) {
    Write-Log $cleanOutput
}
                # ================= ERROR CHECK =================
if ($output -match "Msg\s+\d+") {

    Write-Log "ERROR DETECTED"

    $safeOutput = $output.Replace("'", "''")

    sqlcmd -S $server -d $database -U $user -P $password `
        -Q "INSERT INTO SchemaVersions 
            (ScriptName,DatabaseName,Status,ErrorMessage,ExecutionTime) 
            VALUES ('$fileSafe','$dbSafe','FAILED','$safeOutput',$duration)"

    throw "SQL FAILED: $fileName"
}


                # ================= SUCCESS =================
                sqlcmd -S $server -d $database -U $user -P $password `
                    -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,ScriptHash,Status,ExecutionTime) VALUES ('$fileSafe','$dbSafe','$scriptHash','SUCCESS',$duration)"

                Write-Log "SUCCESS: $fileName"
            }
        }

        Write-Log "===== SUCCESS: $database ====="
    }
    catch {
        Write-Log "===== FAILED: $database ====="
        Write-Log $_.Exception.Message
        Send-Email "Deployment FAILED - $database" $_.Exception.Message
        throw
    }
}

Write-Output "===== Deployment Completed ====="
Send-Email "Deployment SUCCESS" "All databases deployed successfully"