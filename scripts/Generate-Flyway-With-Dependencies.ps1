Write-Output "===== STEP 2: SAFE GENERATION START ====="

$basePath = Get-Location

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
        $files = Get-ChildItem -Path $path -Filter *.sql
        $allFiles += $files
    }
}

Write-Output "Total files: $($allFiles.Count)"

# SAFE ORDER
$sortedFiles = $allFiles | Sort-Object FullName

# GENERATE MIGRATIONS
$migrationPath = Join-Path $basePath "migrations"

if (!(Test-Path $migrationPath)) {
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

$currentTime = Get-Date

foreach ($file in $sortedFiles) {

    $version = $currentTime.ToString("yyyyMMddHHmmss")
    $name = $file.BaseName -replace "[^a-zA-Z0-9]", "_"

    $newFile = "V${version}__${name}.sql"
    $destination = Join-Path $migrationPath $newFile

    Write-Output "Creating: $newFile"

    Get-Content $file.FullName -Raw | Set-Content $destination

    $currentTime = $currentTime.AddSeconds(1)
}

Write-Output "===== STEP 2 COMPLETED SUCCESSFULLY ====="