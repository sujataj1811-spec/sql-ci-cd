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
$smtpUser   = "sujataj1811@gmail.com"
$smtpPass   = "uunf fggb jkbf rmbz"

$fromEmail  = "sujataj1811@gmail.com"
$toEmail    = "sujataj1918@gmail.com"

# ================= PATHS =================
$basePath   = Get-Location
$sqlPath    = $basePath
$dbListFile = Join-Path $basePath "scripts\databases.txt"
$logDir     = "C:\ESD\sql-ci-cd\logs"
$tempDir    = Join-Path $basePath "temp"

Write-Host "Using Log Directory: $logDir"

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

# ================= DBA APPROVAL =================
Write-Output "Waiting for DBA approval..."

$approvalFile = Join-Path $basePath "scripts\approved.txt"

$timeoutMinutes = 30
$startTime = Get-Date

while (-not (Test-Path $approvalFile)) {

    Start-Sleep -Seconds 10

    if ((Get-Date) -gt $startTime.AddMinutes($timeoutMinutes)) {
        throw "Deployment aborted: DBA approval not received within $timeoutMinutes minutes"
    }
}

# ================= READ APPROVAL DETAILS =================
$content = Get-Content $approvalFile

if (($content | Select-Object -First 1).Trim().ToUpper() -ne "APPROVED") {
    throw "Deployment blocked: Invalid approval content"
}

$approvedBy = ""
$approvedOn = ""

foreach ($line in $content) {

    if ($line -match "^By:\s*(.*)") {
        $approvedBy = $matches[1].Trim()
    }

    if ($line -match "^Time:\s*(.*)") {
        $approvedOn = $matches[1].Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($approvedBy)) {
    throw "Approval missing 'By' field"
}

if ([string]::IsNullOrWhiteSpace($approvedOn)) {
    $approvedOn = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

Write-Output "Approved By: $approvedBy"
Write-Output "Approved On: $approvedOn"

Write-Output "DBA approval received. Starting deployment..."

Remove-Item $approvalFile -ErrorAction SilentlyContinue

# ================= DEPLOY SCRIPT =================
$deployScript = {

param ($database, $server, $user, $password, $sqlPath, $logDir, $tempDir, $approvedBy, $approvedOn)

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

function Split-ForeignKeys {
    param ([string]$sqlContent)

    $lines = $sqlContent -split "`r?`n"

    $tableLines = @()
    $fkBlocks = @()

    $insideFK = $false
    $currentFK = ""

    foreach ($line in $lines) {

        # Detect start of FK constraint
        if ($line -match "CONSTRAINT.*FOREIGN KEY" -or $line -match "FOREIGN KEY") {
            $insideFK = $true
            $currentFK = $line
            continue
        }

        if ($insideFK) {
            $currentFK += "`n" + $line

            # End when REFERENCES line closes
            if ($line -match "\)") {
                $fkBlocks += $currentFK
                $insideFK = $false
            }
            continue
        }

        # Remove inline FK (column-level)
        if ($line -match "FOREIGN KEY") {
            continue
        }

        $tableLines += $line
    }

    $cleanSQL = ($tableLines -join "`n")

    # 🔥 Fix trailing comma issue
    $cleanSQL = $cleanSQL -replace ",\s*\)", ")"

    return @{
        TableSQL = $cleanSQL
        FKSQL    = $fkBlocks
    }
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
        ApprovedBy NVARCHAR(100),
        ApprovedOn DATETIME,
        ExecutionTime FLOAT,
        ExecutedOn DATETIME DEFAULT GETDATE()
    )
END
"@

    sqlcmd -S $server -d $database -U $user -P $password -Q $createTable

    $folders = @("01_Tables","02_Views","03_Procedures","04_Functions","05_Triggers","06_Indexes","07_Data")

# ================= DEPENDENCY FUNCTIONS =================

function Get-SqlDependencies {
    param ($filePath)

    $content = Get-Content $filePath -Raw
    $deps = @()


    $matches = [regex]::Matches($content, "(FROM|JOIN)\s+([\[\]\w]+\.[\[\]\w]+)", "IgnoreCase")

    foreach ($m in $matches) {
        $deps += $m.Groups[2].Value.Replace("[","").Replace("]","")
    }

    return $deps | Select-Object -Unique
}

function Resolve-ExecutionOrder {
    param ($files)

    $graph = @{}
    $nameMap = @{}

    foreach ($file in $files) {
        $key = $file.FullName
        $nameMap[$key] = $file
        $graph[$key] = Get-SqlDependencies $file.FullName
    }

    $resolved = New-Object System.Collections.ArrayList
    $unresolved = New-Object System.Collections.ArrayList

    function Resolve($node) {
        if ($resolved -contains $node) { return }

if ($unresolved -contains $node) {
    Write-Log "WARNING: Circular dependency ignored for $node"
    return
}

        [void]$unresolved.Add($node)

        foreach ($dep in $graph[$node]) {
           $depNode = $graph.Keys | Where-Object { $_ -like "*$dep*" } | Select-Object -First 1

            if ($depNode) {
               if ($depNode) {
    Resolve $depNode
}
            }
        }

        $unresolved.Remove($node)
        [void]$resolved.Add($node)
    }

    foreach ($node in $graph.Keys) {
        Resolve $node
    }

    return $resolved
}
# ================= COLLECT ALL FILES =================
$allFiles = @()

foreach ($folder in $folders) {
    $folderPath = Join-Path $sqlPath $folder
    if (Test-Path $folderPath) {
        $allFiles += Get-ChildItem "$folderPath\*.sql"
    }
}

# ================= RESOLVE DEPENDENCY ORDER =================
$orderedPaths = Resolve-ExecutionOrder $allFiles

foreach ($filePath in $orderedPaths) {

    $file = Get-Item $filePath
    $fileName   = $file.Name
    $fileSafe   = $fileName.Replace("'","''")
    $dbSafe     = $database.Replace("'","''")
    $scriptHash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

    Write-Log "Executing (dependency) $fileName..."

    $sqlContent = Get-Content $file.FullName -Raw

$split = Split-ForeignKeys -sqlContent $sqlContent

$tableSQL = $split.TableSQL
$fkList   = $split.FKSQL
    $sql = $sqlContent.ToUpper()

    if ($sql.Contains("DROP DATABASE") -or $sql.Contains("TRUNCATE TABLE")) {
        Write-Log "BLOCKED SCRIPT: $fileName"
        continue
    }

    if ($sql.Contains("DELETE FROM") -and -not ($sql.Contains("WHERE"))) {
        Write-Log "BLOCKED DELETE WITHOUT WHERE: $fileName"
        continue
    }

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

    $start = Get-Date
    $script:LastError = $false

    $usesGO = Test-UsesGO -content $sqlContent

    if ($usesGO) {
        $output = sqlcmd -S $server -d $database -U $user -P $password -i $file.FullName -b 2>&1 | Out-String
    }
    else {
        try {
            $output = Invoke-Sqlcmd -ServerInstance $server -Database $database -Username $user -Password $password -Query $tableSQL -ErrorAction Stop | Out-String
        }
        catch {
            $output = $_.Exception.Message
            $script:LastError = $true
        }
    }

    $duration = ((Get-Date) - $start).TotalSeconds
    Write-Log $output

    if ($LASTEXITCODE -ne 0 -or $script:LastError) {

        $safeOutput = $output.Replace("'", "''")

        sqlcmd -S $server -d $database -U $user -P $password `
        -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,ScriptHash,Status,ErrorMessage,ApprovedBy,ApprovedOn,ExecutionTime)
            VALUES ('$fileSafe','$dbSafe','$scriptHash','FAILED','$safeOutput','$approvedBy','$approvedOn',$duration)"

        throw "SQL FAILED: $fileName"
    }

    sqlcmd -S $server -d $database -U $user -P $password `
    -Q "INSERT INTO SchemaVersions (ScriptName,DatabaseName,ScriptHash,Status,ApprovedBy,ApprovedOn,ExecutionTime)
        VALUES ('$fileSafe','$dbSafe','$scriptHash','SUCCESS','$approvedBy','$approvedOn',$duration)"

    Write-Log "$fileName executed in $duration sec"
}
 
foreach ($fk in $fkList) {

    $fkQuery = @"
ALTER TABLE $($tableNameMatch = [regex]::Match($tableSQL, "CREATE TABLE\s+([\[\]\w\.]+)", "IgnoreCase")
$tableName = $tableNameMatch.Groups[1].Value)
ADD $fk
"@

    try {
        Invoke-Sqlcmd `
            -ServerInstance $server `
            -Database $database `
            -Username $user `
            -Password $password `
            -Query $fkQuery `
            -ErrorAction Stop | Out-Null

        Write-Log "FK Applied: $fk"
    }
    catch {
        Write-Log "FK FAILED: $fk"
        throw $_
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
        -ArgumentList $db, $server, $user, $password, $sqlPath, $logDir, $tempDir, $approvedBy, $approvedOn

    [void]$jobs.Add($job)
}

foreach ($job in $jobs) {

    Wait-Job $job | Out-Null
    Receive-Job $job -Keep

    if ($job.State -eq "Failed") {
        $global:DeploymentFailed = $true
    }
}

# ================= EMAIL =================
$status = if ($global:DeploymentFailed) { "FAILED" } else { "SUCCESS" }

Write-Output "===== Deployment Completed: $status ====="