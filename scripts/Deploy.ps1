Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server       = $env:DB_SERVER
$user         = $env:DB_USER
$password     = $env:DB_PASSWORD
$maxParallel  = 1

# ================= EMAIL CONFIG =================
$smtpServer   = "smtp.gmail.com"
$smtpPort     = 587
$emailFrom    = "your_email@gmail.com"
$emailTo      = "your_email@gmail.com"
$emailPassword= "your_app_password"

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath   # ✅ FIXED
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = Join-Path $basePath "logs"
$tempDir    = Join-Path $basePath "temp"

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
    $logFile  = Join-Path $logDir "deployment_$database.log"

    function Write-Log {
        param ($msg)
        $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$time - $msg"
    }

    try {
        Write-Log "===== START: $database ====="

        # ✅ Ensure SchemaVersions table exists
        $createTable = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SchemaVersions')
BEGIN
    CREATE TABLE SchemaVersions (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        ScriptName NVARCHAR(255),
        DatabaseName NVARCHAR(100),
        Status NVARCHAR(20),
        ErrorMessage NVARCHAR(MAX),
        RollbackScript NVARCHAR(MAX),
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

                $fileName = $file.Name
                Write-Log "Executing: $fileName"

                # ================= SKIP =================
                $check = sqlcmd -S $server -d $database -U $user -P $password `
                    -Q "IF EXISTS (SELECT 1 FROM SchemaVersions WHERE ScriptName='$fileName' AND Status='SUCCESS') SELECT 1 ELSE SELECT 0" `
                    -h -1 -W | Out-String

                if ($check.Trim() -eq "1") {
                    Write-Log "SKIPPED: $fileName"
                    continue
                }

                # ================= TEMP FILE =================
                $tempFile = Join-Path $tempDir "$($file.BaseName)_$database.sql"

@"
USE [$database]
GO
:r "$($file.FullName)"
"@ | Out-File -Encoding utf8 $tempFile

                # ================= EXECUTION =================
                $start = Get-Date

                $output = sqlcmd -S $server `
                 -U $user `
                 -P $password `
                 -i "$tempFile" `
                 -r 1 -W -h -1 2>&1 | Out-String

                $duration = ((Get-Date) - $start).TotalSeconds

                Write-Log $output

                # ================= ERROR CHECK =================
               if ($output -match "Msg\s+\d+") {
    Write-Host "===== SQL ERROR OUTPUT ====="
    Write-Host $output
    throw "SQL execution failed"
} {

                    Write-Log "ERROR: $output"

                    sqlcmd -S $server -d $database -U $user -P $password `
                        -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,Status,ErrorMessage,ExecutionTime) VALUES ('$fileName','$database','FAILED','$output',$duration)"

                    throw "SQL FAILED: $fileName"
                }

                # ================= SUCCESS =================
                sqlcmd -S $server -d $database -U $user -P $password `
                    -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,Status,ExecutionTime) VALUES ('$fileName','$database','SUCCESS',$duration)"

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