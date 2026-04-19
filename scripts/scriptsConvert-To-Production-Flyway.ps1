Write-Output "===== CONVERTING TO FLYWAY STRUCTURE ====="

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

# Clean migrations folder
if (Test-Path $migrationPath) {
    Remove-Item -Recurse -Force $migrationPath
}
New-Item -ItemType Directory -Path $migrationPath | Out-Null

# Output files
$files = @{
    "V1__schemas.sql" = ""
    "V2__types.sql" = ""
    "V3__tables.sql" = ""
    "V4__primary_keys.sql" = ""
    "V5__foreign_keys.sql" = ""
    "V6__defaults_and_constraints.sql" = ""
    "V7__indexes.sql" = ""
    "R__views.sql" = ""
    "R__procedures.sql" = ""
    "R__functions.sql" = ""
    "R__triggers.sql" = ""
}

# Helper function
function Append-ToFile {
    param($fileName, $content)

    if ($content -and $content.Trim() -ne "") {
        $files[$fileName] += "`nGO`n" + $content + "`n"
    }
}

# ================= PROCESS TABLES =================
Write-Output "Processing Tables..."

$tablePath = Join-Path $basePath "01_Tables"
if (Test-Path $tablePath) {

    Get-ChildItem "$tablePath\*.sql" | ForEach-Object {

        $content = Get-Content $_.FullName -Raw

        # Extract CREATE TABLE
        if ($content -match "CREATE\s+TABLE") {
            Append-ToFile "V3__tables.sql" $content
        }

        # Extract PK
        if ($content -match "PRIMARY\s+KEY") {
            Append-ToFile "V4__primary_keys.sql" $content
        }

        # Extract FK
        if ($content -match "FOREIGN\s+KEY") {
            Append-ToFile "V5__foreign_keys.sql" $content
        }

        # Extract DEFAULT / CHECK
        if ($content -match "DEFAULT|CHECK") {
            Append-ToFile "V6__defaults_and_constraints.sql" $content
        }

        # Extract INDEX
        if ($content -match "INDEX") {
            Append-ToFile "V7__indexes.sql" $content
        }
    }
}

# ================= PROCESS VIEWS =================
Write-Output "Processing Views..."

$viewPath = Join-Path $basePath "02_Views"
if (Test-Path $viewPath) {
    Get-ChildItem "$viewPath\*.sql" | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content = $content -replace "CREATE\s+VIEW", "CREATE OR ALTER VIEW"
        Append-ToFile "R__views.sql" $content
    }
}

# ================= PROCESS PROCEDURES =================
Write-Output "Processing Procedures..."

$procPath = Join-Path $basePath "03_Procedures"
if (Test-Path $procPath) {
    Get-ChildItem "$procPath\*.sql" | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content = $content -replace "CREATE\s+PROCEDURE", "CREATE OR ALTER PROCEDURE"
        Append-ToFile "R__procedures.sql" $content
    }
}

# ================= PROCESS FUNCTIONS =================
Write-Output "Processing Functions..."

$funcPath = Join-Path $basePath "04_Functions"
if (Test-Path $funcPath) {
    Get-ChildItem "$funcPath\*.sql" | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content = $content -replace "CREATE\s+FUNCTION", "CREATE OR ALTER FUNCTION"
        Append-ToFile "R__functions.sql" $content
    }
}

# ================= PROCESS TRIGGERS =================
Write-Output "Processing Triggers..."

$trigPath = Join-Path $basePath "05_Triggers"
if (Test-Path $trigPath) {
    Get-ChildItem "$trigPath\*.sql" | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content = $content -replace "CREATE\s+TRIGGER", "CREATE OR ALTER TRIGGER"
        Append-ToFile "R__triggers.sql" $content
    }
}

# ================= WRITE FILES =================

foreach ($key in $files.Keys) {
    $path = Join-Path $migrationPath $key
    Set-Content $path $files[$key]
    Write-Output "Created $key"
}

Write-Output "===== CONVERSION COMPLETED ====="