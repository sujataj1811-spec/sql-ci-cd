Write-Output "===== GENERATING SAFE FLYWAY MIGRATIONS (FINAL VERSION) ====="

# ================= CONFIG =================

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

if (!(Test-Path $migrationPath)) {
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

# ================= VALIDATE ENV =================

if (-not $env:DB_SERVER) { throw "DB_SERVER not set" }
if (-not $env:DB_NAME)   { throw "DB_NAME not set" }
if (-not $env:DB_USER)   { throw "DB_USER not set" }
if (-not $env:DB_PASSWORD) { throw "DB_PASSWORD not set" }

Write-Output "Connected to DB: $($env:DB_NAME) on $($env:DB_SERVER)"

# ================= STEP 1: ENSURE SCHEMAS =================

Write-Output "===== STEP 1: SCHEMA BOOTSTRAP ====="

$schemas = @("dbo", "HumanResources", "Sales", "Person", "Production")

foreach ($schema in $schemas) {

    $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '$schema')
BEGIN
    EXEC('CREATE SCHEMA [$schema]');
END
"@

    Invoke-Sqlcmd `
        -ServerInstance $env:DB_SERVER `
        -Database $env:DB_NAME `
        -Username $env:DB_USER `
        -Password $env:DB_PASSWORD `
        -Query $query `
        -ErrorAction Stop

    Write-Output "✔ Schema ensured: $schema"
}

# ================= STEP 2: LOAD FILES =================

$folders = @(
    "01_Tables",
    "02_Views",
    "04_Functions",
    "03_Procedures",
    "05_Triggers"
)

$allFiles = @()

foreach ($folder in $folders) {
    $path = Join-Path $basePath $folder
    if (Test-Path $path) {
        $allFiles += Get-ChildItem "$path\*.sql" -ErrorAction SilentlyContinue
    }
}

Write-Output "Total SQL files found: $($allFiles.Count)"

if ($allFiles.Count -eq 0) {
    throw "No SQL files found to execute"
}

# ================= STEP 3: EXECUTION =================

Write-Output "===== STEP 3: EXECUTION START ====="

foreach ($file in $allFiles) {

    try {
        Write-Output "Executing: $($file.FullName)"

        $sql = Get-Content $file.FullName -Raw

        Invoke-Sqlcmd `
            -ServerInstance $env:DB_SERVER `
            -Database $env:DB_NAME `
            -Username $env:DB_USER `
            -Password $env:DB_PASSWORD `
            -Query $sql `
            -ErrorAction Stop

        Write-Output "✔ SUCCESS: $($file.Name)"
    }
    catch {
        Write-Output "❌ FAILED: $($file.Name)"
        Write-Output $_.Exception.Message
        throw
    }
}

Write-Output "===== DEPLOYMENT COMPLETED SUCCESSFULLY ====="