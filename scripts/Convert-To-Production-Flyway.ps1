Write-Output "===== Converting to Production Flyway Structure ====="

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

if (!(Test-Path $migrationPath)) {
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

# Source folders
$tablesPath     = Join-Path $basePath "01_Tables"
$viewsPath      = Join-Path $basePath "02_Views"
$procPath       = Join-Path $basePath "03_Procedures"
$funcPath       = Join-Path $basePath "04_Functions"
$triggerPath    = Join-Path $basePath "05_Triggers"
$indexPath      = Join-Path $basePath "06_Indexes"
$dataPath       = Join-Path $basePath "07_Data"

# ================= CREATE VERSIONED FILE =================
$versionFile = Join-Path $migrationPath "V1__baseline_schema.sql"
"" | Set-Content $versionFile

function Append-Files {
    param ($path)

    if (Test-Path $path) {
        Get-ChildItem "$path\*.sql" | Sort-Object Name | ForEach-Object {
            Write-Output "Adding to V file: $($_.Name)"
            Add-Content $versionFile "`nGO`n"
            Get-Content $_.FullName | Add-Content $versionFile
        }
    }
}

# Tables + Indexes + Data → V
Append-Files $tablesPath
Append-Files $indexPath
Append-Files $dataPath

# ================= CREATE REPEATABLE FILES =================

function Create-RFile {
    param ($name, $path)

    $file = Join-Path $migrationPath $name
    "" | Set-Content $file

    if (Test-Path $path) {
        Get-ChildItem "$path\*.sql" | Sort-Object Name | ForEach-Object {
            Write-Output "Adding to $name : $($_.Name)"

            Add-Content $file "`nGO`n"

            # IMPORTANT: convert to CREATE OR ALTER
            $content = Get-Content $_.FullName -Raw
            $content = $content -replace "CREATE\s+VIEW", "CREATE OR ALTER VIEW"
            $content = $content -replace "CREATE\s+PROCEDURE", "CREATE OR ALTER PROCEDURE"
            $content = $content -replace "CREATE\s+FUNCTION", "CREATE OR ALTER FUNCTION"

            Add-Content $file $content
        }
    }
}

Create-RFile "R__views.sql" $viewsPath
Create-RFile "R__procedures.sql" $procPath
Create-RFile "R__functions.sql" $funcPath
Create-RFile "R__triggers.sql" $triggerPath

Write-Output "===== Production Flyway Conversion Completed ====="