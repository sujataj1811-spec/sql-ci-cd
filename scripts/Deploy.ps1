Write-Output "===== SQL CI/CD Deployment Started ====="
$ErrorActionPreference = "Stop"

$server       = $env:DB_SERVER
$user         = $env:DB_USER
$password     = $env:DB_PASSWORD

$basePath   = Get-Location
$sqlPath    = $basePath
$dbListFile = Join-Path $basePath "scripts\databases.txt"

Write-Output "Looking for DB file at: $dbListFile"

if (!(Test-Path $dbListFile)) {
    throw "databases.txt not found!"
}

$databases = Get-Content $dbListFile | Where-Object { $_.Trim() -ne "" }

foreach ($db in $databases) {

    Write-Output "Processing DB: $db"

    $folders = @("01_Tables","02_Views","03_Procedures","04_Functions","05_Triggers","06_Indexes","07_Data")

    foreach ($folder in $folders) {

        $folderPath = Join-Path $sqlPath $folder
        if (!(Test-Path $folderPath)) { continue }

        $files = Get-ChildItem "$folderPath\*.sql" -ErrorAction SilentlyContinue

        foreach ($file in $files) {

            Write-Output "Running $($file.Name)"

            sqlcmd -S $server -U $user -P $password -d $db -i $file.FullName
        }
    }
}

Write-Output "Deployment Completed"