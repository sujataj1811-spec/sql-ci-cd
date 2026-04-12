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
$sqlPath    = $basePath
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

# ================= VALIDATION =================
if (!(Test-Path $sqlPath)) { throw "Project root not found!" }

# DEBUG PATH
Write-Output "Looking for DB file at: $dbListFile"

# CHECK FILE
if (!(Test-Path $dbListFile)) {
    throw "databases.txt not found!"
}

# READ DATABASES
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
            Add-Content -Path $logFile -Value "$time - $message"
        }

        $database = $database.Trim()
        $logFile  = Join-Path $logDir "deployment_$database.log"

        try {
            Write-Log "===== START: $database =====" $logFile

            foreach ($folder in $folders) {

                $folderPath = Join-Path $sqlPath $folder
                if (!(Test-Path $folderPath)) { continue }

                Write-Log "Processing Folder: $folder" $logFile

                $files = Get-ChildItem "$folderPath\*.sql" -ErrorAction SilentlyContinue

                foreach ($file in $files) {

                    Write-Log "Executing $($file.Name)" $logFile

                    $output = sqlcmd -S $server `
                                     -U $user `
                                     -P $password `
                                     -d $database `
                                     -i $file.FullName 2>&1 | Out-String

                    if ($output -match "Msg\s+\d+") {
                        Write-Log "ERROR: $output" $logFile
                        throw "SQL execution failed"
                    }

                    Write-Log "Completed $($file.Name)" $logFile
                }
            }

            Write-Log "===== SUCCESS: $database =====" $logFile
        }
        catch {
            Write-Log "===== FAILED: $database =====" $logFile
            Write-Log $_.Exception.Message $logFile
            throw
        }

    } -ArgumentList $db, $folders, $sqlPath, $server, $user, $password, $logDir, $tempDir
}

# ================= WAIT =================
foreach ($job in $jobs) {
    Wait-Job $job
    Receive-Job $job -ErrorAction Continue
    Remove-Job $job
}

# ================= FINAL STATUS =================
Write-Output "Deployment Completed"