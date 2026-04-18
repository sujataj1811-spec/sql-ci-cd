Write-Output "===== GENERATING SAFE FLYWAY MIGRATIONS (ENTERPRISE SAFE MODE) ====="

# ================= CONFIG =================

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

if (!(Test-Path $migrationPath)) {
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

# ================= STEP 1: ENSURE SCHEMAS =================
Write-Output "===== STEP 1: SCHEMA BOOTSTRAP ====="

$schemas = @("dbo", "HumanResources", "Sales", "Person", "Production")

foreach ($schema in $schemas) {
    $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '$schema')
    EXEC('CREATE SCHEMA [$schema]');
"@

    Invoke-Sqlcmd -ServerInstance $env:DB_SERVER `
                  -Database $env:DB_NAME `
                  -Query $query

    Write-Output "✔ Schema ensured: $schema"
}

# ================= STEP 2: LOAD FILES =================

$folders = @(
    "01_Tables",
    "02_Views",
    "03_Procedures",
    "04_Functions",
    "05_Triggers"
)

$allFiles = @()

foreach ($folder in $folders) {
    $path = Join-Path $basePath $folder
    if (Test-Path $path) {
        $allFiles += Get-ChildItem "$path\*.sql"
    }
}

Write-Output "Total SQL files found: $($allFiles.Count)"

# ================= STEP 3: SIMPLE SAFE ORDER =================

$orderMap = @{
    "01_Tables"     = 1
    "02_Views"      = 2
    "03_Procedures" = 3
    "04_Functions"  = 4
    "05_Triggers"   = 5
}

$sortedFiles = $allFiles | Sort-Object {
    $order = 99
    foreach ($key in $orderMap.Keys) {
        if ($_.FullName -match $key) {
            $order = $orderMap[$key]
        }
    }
    $order
}

# ================= STEP 4: EXECUTION =================

Write-Output "===== STEP 4: EXECUTION START ====="

foreach ($file in $sortedFiles) {

    try {
        Write-Output "Executing: $($file.Name)"

        $sql = Get-Content $file.FullName -Raw

        Invoke-Sqlcmd -ServerInstance $env:DB_SERVER `
                      -Database $env:DB_NAME `
                      -Query $sql `
                      -ErrorAction Stop

        Write-Output "✔ SUCCESS: $($file.Name)"
    }
    catch {
        Write-Output "❌ FAILED: $($file.Name)"
        Write-Output $_.Exception.Message
        throw "Migration failed at $($file.Name)"
    }
}

Write-Output "===== DEPLOYMENT COMPLETED SUCCESSFULLY ====="