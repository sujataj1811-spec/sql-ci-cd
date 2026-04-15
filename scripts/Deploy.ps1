Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

# ================= CONFIG =================
$server      = $env:DB_SERVER
$user        = $env:DB_USER
$password    = $env:DB_PASSWORD
$maxParallel = 3

# ================= EMAIL CONFIG =================
$smtpServer = "smtp.gmail.com"
$smtpPort   = 587
$smtpUser   = "your_email@gmail.com"
$smtpPass   = "your_app_password"

$fromEmail  = "your_email@gmail.com"
$toEmail    = "receiver_email@gmail.com"

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

    function Test-UsesGO {
        param ([string]$content)
        $lines = $content -split "`r?`n"
        foreach ($line in $lines) {
            if ($line.Trim().ToUpper() -eq "GO") {
                return $true
            }
        }
        return $false
    }

    # ================= TRACKING TABLE =================
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

    # ================= FOLDERS ORDER =================
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
            $sqlContent = Get-Content $file.FullName -Raw
            $sql = $sqlContent.ToUpper()

            if ($sql.Contains("DROP DATABASE") -or $sql.Contains("TRUNCATE TABLE")) {
                Write-Log "BLOCKED SCRIPT: $fileName"
                continue
            }

            if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) {
                Write-Log "BLOCKED DELETE WITHOUT WHERE: $fileName"
                continue
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
            $script:LastError = $false

            $usesGO = Test-UsesGO -content $sqlContent

            Write-Log "Execution Mode: $(if ($usesGO) { 'sqlcmd (multi-batch)' } else { 'Invoke-Sqlcmd (single-batch)' })"

            if ($usesGO) {
                Write-Log "Using sqlcmd (GO detected)"

                $output = sqlcmd `
                    -S $server `
                    -d $database `
                    -U $user `
                    -P $password `
                    -i $file.FullName `
                    -b 2>&1 | Out-String
            }
            else {
                Write-Log "Using Invoke-Sqlcmd (single batch)"

                try {
                    $output = Invoke-Sqlcmd `
                        -ServerInstance $server `
                        -Database $database `
                        -Username $user `
			-Password $password `
			-Query $sqlContent `
                        -ErrorAction Stop | Out-String
                }
                catch {
                    $output = $_.Exception.Message
                    $script:LastError = $true
                }
            }

            $duration = ((Get-Date) - $start).TotalSeconds
            Write-Log $output

            # ================= ERROR CHECK =================
            if ($LASTEXITCODE -ne 0 -or $script:LastError) {

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
$global:DeploymentFailed = $false
$jobs = New-Object System.Collections.ArrayList

foreach ($db in $databases) {

    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $maxParallel) {
        Start-Sleep 2
    }

    $job = Start-Job -ScriptBlock $deployScript `
        -ArgumentList $db, $server, $user, $password, $sqlPath, $logDir, $tempDir

    [void]$jobs.Add($job)
}

foreach ($job in $jobs) {

    if ($null -eq $job) { continue }

    try {
        Wait-Job -Job $job -ErrorAction SilentlyContinue
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Host "Job failed"
        $global:DeploymentFailed = $true
    }

    if ($job.State -eq "Failed") {
        Write-Host "Job FAILED: $($job.Id)"
        $global:DeploymentFailed = $true
    }
}

# ================= EMAIL =================
function Send-DeploymentEmail {
    param (
        [string]$status,
        [string]$logDir
    )

    $subject = "SQL CI/CD Deployment - $status"

    $body = @"
Deployment Status: $status

Server: $server
Databases: $($databases -join ", ")

Logs Location: $logDir

Time: $(Get-Date)
"@

    $securePass = ConvertTo-SecureString $smtpPass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($smtpUser, $securePass)

    Send-MailMessage `
        -From $fromEmail `
        -To $toEmail `
        -Subject $subject `
        -Body $body `
        -SmtpServer $smtpServer `
        -Port $smtpPort `
        -UseSsl `
        -Credential $cred
}

$status = if ($global:DeploymentFailed) { "FAILED" } else { "SUCCESS" }

Send-DeploymentEmail -status $status -logDir $logDir

Write-Output "===== Deployment Completed: $status ====="