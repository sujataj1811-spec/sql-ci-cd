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
$sqlPath = "$PSScriptRoot/sql-ci-cd"
$dbListFile = Join-Path $basePath "databases.txt"
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
if (!(Test-Path $sqlPath))    { throw "sql-ci-cd folder not found!" }
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
            Add-Content -Path $logFile -Value "$time - $message"
        }

        function Validate-SqlScript {
            param ($filePath, $database, $server, $user, $password, $logFile)

            $content = Get-Content $filePath -Raw
            $contentClean = $content -replace '--.*', '' -replace '/\*[\s\S]*?\*/', ''
            $sql = $contentClean.ToUpper()

            if ($sql.Contains("DROP DATABASE")) {
                Write-Log "BLOCKED: DROP DATABASE found in $filePath" $logFile
                return $false
            }

            if ($sql.Contains("TRUNCATE TABLE")) {
                Write-Log "BLOCKED: TRUNCATE TABLE found in $filePath" $logFile
                return $false
            }

            if ($sql.Contains("DROP TABLE")) {
                Write-Log "WARNING: DROP TABLE detected in $filePath" $logFile
            }

            if ($sql.Contains("ALTER TABLE") -and $sql.Contains("DROP COLUMN")) {
                Write-Log "WARNING: DROP COLUMN detected in $filePath" $logFile
            }

            if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) {
                Write-Log "BLOCKED: DELETE without WHERE in $filePath" $logFile
                return $false
            }

            if ($sql.Contains("UPDATE") -and -not ($sql.Contains("WHERE"))) {
                Write-Log "WARNING: UPDATE without WHERE in $filePath" $logFile
            }

            # Syntax validation
            $tempValidationFile = Join-Path ([System.IO.Path]::GetTempPath()) ("validate_" + [guid]::NewGuid() + ".sql")

@"
SET PARSEONLY ON
GO
USE [$database]
GO
$content
GO
SET PARSEONLY OFF
"@ | Out-File -Encoding utf8 $tempValidationFile

            $validationOutput = sqlcmd -S $server -U $user -P $password -i $tempValidationFile -b 2>&1 | Out-String
            Remove-Item $tempValidationFile -ErrorAction SilentlyContinue

            if ($validationOutput -match "Msg\s+\d+") {
                Write-Log "Syntax Error in $filePath" $logFile
                Write-Log $validationOutput $logFile
                return $false
            }

            Write-Log "Validation Passed: $filePath" $logFile
            return $true
        }

        function Rollback-LastScript {
            param ($database, $server, $user, $password, $logFile, $scriptName)

            Write-Log "Rolling back script: $scriptName" $logFile

            $query = @"
SELECT TOP 1 RollbackScript
FROM SchemaVersions
WHERE DatabaseName = '$database'
AND ScriptName = '$scriptName'
AND Status = 'SUCCESS'
ORDER BY Id DESC
"@

            $rollbackScript = sqlcmd -S $server -d $database -U $user -P $password -Q $query -h -1 -W | Out-String

            if ($rollbackScript.Trim() -ne "") {
                sqlcmd -S $server -d $database -U $user -P $password -Q $rollbackScript
                Write-Log "Rollback completed for $scriptName" $logFile
            }
            else {
                Write-Log "No rollback script found for $scriptName" $logFile
            }
        }

        $database = $database.Trim()
        $logFile  = Join-Path $logDir "deployment_$database.log"

        try {
            Write-Log "===== START: $database =====" $logFile

            foreach ($folder in $folders) {

                $folderPath = Join-Path $sqlPath $folder
                if (!(Test-Path $folderPath)) { continue }

                Write-Log "Processing Folder: $folder" $logFile

                $files = Get-ChildItem "$folderPath\*.sql" |
                         Sort-Object { [int]($_.BaseName -replace '[^\d]', '') }

                foreach ($file in $files) {

                    $fileName   = $file.Name
                    $fileSafe   = $fileName.Replace("'","''")
                    $dbSafe     = $database.Replace("'","''")
                    $scriptHash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

                    # ================= SKIP CHECK =================
                    $checkQuery = @"
SET NOCOUNT ON;
IF EXISTS (
    SELECT 1 FROM SchemaVersions
    WHERE ScriptName = '$fileSafe'
    AND DatabaseName = '$dbSafe'
    AND Status = 'SUCCESS'
)
SELECT 1 ELSE SELECT 0
"@

                    $result = sqlcmd -S $server -d $database -U $user -P $password -Q $checkQuery -h -1 -W
                    $result = ($result | Out-String)

                    if ($result -match "1") {
                        Write-Log "SKIPPING (already deployed): $fileName" $logFile
                        continue
                    }

                    if (-not (Validate-SqlScript $file.FullName $database $server $user $password $logFile)) {
                        throw "Validation failed for $fileName"
                    }

                    Write-Log "Executing $fileName..." $logFile

                    $scriptContent = Get-Content $file.FullName -Raw
                    $rollbackScript = ""

                    if ($scriptContent -match "(?s)--\s*ROLLBACK(.*)$") {
                        $rollbackScript = $matches[1].Trim().Replace("'", "''")
                    }

                    $tempFile = Join-Path $tempDir "$($file.BaseName).$database.$([guid]::NewGuid()).sql"

@"
USE [$database]
GO
:r "$($file.FullName)"
"@ | Out-File -Encoding utf8 $tempFile

                    # ================= EXECUTE =================
                    $startTime = Get-Date

                    $output = sqlcmd -S $server `
                                     -U $user `
                                     -P $password `
                                     -i "$tempFile" `
                                     -b -r 1 -W -h -1 2>&1 | Out-String

                    $endTime  = Get-Date
                    $duration = ($endTime - $startTime).TotalSeconds

                    Write-Log "$fileName executed in $duration sec" $logFile

                    # ================= ERROR DETECTION =================
                    $hasError = $false

                    if ($output -match "Msg\s+\d+") { $hasError = $true }
                    elseif ($output -match "Invalid|Cannot|Error|Failed") { $hasError = $true }

                    if ($hasError) {

                        $err = $output.Substring(0, [Math]::Min(3000, $output.Length)).Replace("'", "''")

                        Write-Log "ERROR: $err" $logFile

                        $insertFail = @"
INSERT INTO SchemaVersions 
(ScriptName, DatabaseName, Status, ErrorMessage, RollbackScript, ExecutionTime)
VALUES 
('$fileSafe', '$dbSafe', 'FAILED', '$err', '$rollbackScript', $duration)
"@

                        sqlcmd -S $server -d $database -U $user -P $password -Q $insertFail

                        Rollback-LastScript $database $server $user $password $logFile $fileSafe

                        throw "Error executing $fileName"
                    }

                    # ================= SUCCESS =================
                    $insertSuccess = @"
INSERT INTO SchemaVersions 
(ScriptName, DatabaseName, Status, RollbackScript, ExecutionTime)
VALUES 
('$fileSafe', '$dbSafe', 'SUCCESS', '$rollbackScript', $duration)
"@

                    sqlcmd -S $server -d $database -U $user -P $password -Q $insertSuccess

                    Write-Log "Completed $fileName" $logFile
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
    Remove-Job $job
}

# ================= FINAL STATUS =================
$failed = $jobs | Where-Object { $_.State -ne "Completed" }

if ($failed.Count -gt 0) {
    Write-Output "Deployment FAILED"
    Send-Email "Deployment FAILED" "Check logs in $logDir"
    exit 1
}
else {
    Write-Output "Deployment SUCCESS"
    Send-Email "Deployment SUCCESS" "All databases deployed successfully"
}