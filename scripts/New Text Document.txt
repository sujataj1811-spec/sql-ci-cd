Write-Output "===== Converting to Timestamp-Based Flyway Migrations ====="

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

if (!(Test-Path $migrationPath)) {
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

# Folder execution order
$folders = @(
    "01_Tables",
    "02_Views",
    "03_Procedures",
    "04_Functions",
    "05_Triggers",
    "06_Indexes",
    "07_Data"
)

# Start timestamp
$currentTime = Get-Date

foreach ($folder in $folders) {

    $folderPath = Join-Path $basePath $folder
    if (!(Test-Path $folderPath)) { continue }

    $files = Get-ChildItem "$folderPath\*.sql" | Sort-Object Name

    foreach ($file in $files) {

        # Generate timestamp (yyyyMMddHHmmss)
        $version = $currentTime.ToString("yyyyMMddHHmmss")

        # Clean file name
        $desc = $file.BaseName -replace "[^a-zA-Z0-9]", "_"

        $newFileName = "V${version}__${desc}.sql"
        $destination = Join-Path $migrationPath $newFileName

        Write-Output "Creating $newFileName"

        $content = Get-Content $file.FullName -Raw

        Set-Content -Path $destination -Value $content

        # Add 1 second to maintain order
        $currentTime = $currentTime.AddSeconds(1)
    }
}

Write-Output "===== Conversion Completed ====="