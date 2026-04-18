Write-Output "===== Generating Dependency-Based Flyway Migrations ====="

# ================= FUNCTIONS (ADD HERE) =================

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

    foreach ($file in $files) {
        $graph[$file.FullName] = Get-SqlDependencies $file.FullName
    }

    $resolved = New-Object System.Collections.ArrayList
    $unresolved = New-Object System.Collections.ArrayList

    function Resolve($node) {

        if ($resolved -contains $node) { return }

        if ($unresolved -contains $node) {
            Write-Host "⚠ Circular dependency: $node"
            return
        }

        [void]$unresolved.Add($node)

        foreach ($dep in $graph[$node]) {
            $depNode = $graph.Keys | Where-Object { $_ -match [regex]::Escape($dep) } | Select-Object -First 1
            if ($depNode) {
                Resolve $depNode
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

# ================= MAIN SCRIPT STARTS HERE =================


$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

if (!(Test-Path $migrationPath)) {
    New-Item -ItemType Directory -Path $migrationPath | Out-Null
}

# Source folders (priority still matters slightly)
$folders = @(
    "01_Tables",
    "02_Views",
    "03_Procedures",
    "04_Functions",
    "05_Triggers",
    "06_Indexes",
    "07_Data"
)

# ================= READ FILES =================
$allFiles = @()

foreach ($folder in $folders) {
    $folderPath = Join-Path $basePath $folder
    if (Test-Path $folderPath) {
        $allFiles += Get-ChildItem "$folderPath\*.sql"
    }
}

# ================= EXTRACT DEPENDENCIES =================
function Get-Dependencies {
    param ($file)

    $content = Get-Content $file.FullName -Raw
    $deps = @()

    # Match schema + table/view
    $matches1 = [regex]::Matches($content, "(FROM|JOIN)\s+([\[\]\w]+\.[\[\]\w]+)", "IgnoreCase")

    # Match without schema (VERY IMPORTANT)
    $matches2 = [regex]::Matches($content, "(FROM|JOIN)\s+([\[\]\w]+)", "IgnoreCase")

    foreach ($m in $matches1) {
        $deps += $m.Groups[2].Value.Replace("[","").Replace("]","")
    }

    foreach ($m in $matches2) {
        $deps += $m.Groups[2].Value.Replace("[","").Replace("]","")
    }

    return $deps | Select-Object -Unique
}

# ================= BUILD GRAPH =================
$graph = @{}
$nameMap = @{}

foreach ($file in $allFiles) {
    $key = $file.FullName
    $nameMap[$key] = $file
    $graph[$key] = Get-Dependencies $file
}

# ================= TOPOLOGICAL SORT =================
$resolved = New-Object System.Collections.ArrayList
$unresolved = New-Object System.Collections.ArrayList

function Resolve($node) {

    if ($resolved -contains $node) { return }

    if ($unresolved -contains $node) {
        Write-Output "⚠️ Circular dependency detected: $node"
        return
    }

    [void]$unresolved.Add($node)

    foreach ($dep in $graph[$node]) {

        # Match dependency file
        $depNode = $graph.Keys | Where-Object {
    (Split-Path $_ -Leaf) -like "*$dep*"
} | Select-Object -First 1

        if ($depNode) {
            Resolve $depNode
        }
    }

    $unresolved.Remove($node)
    [void]$resolved.Add($node)
}

foreach ($node in $graph.Keys) {
    Resolve $node
}

# ================= GENERATE FLYWAY FILES =================
$currentTime = Get-Date

foreach ($path in $resolved) {

    $file = $nameMap[$path]

    $version = $currentTime.ToString("yyyyMMddHHmmss")
    $desc = $file.BaseName -replace "[^a-zA-Z0-9]", "_"

    $newFile = "V${version}__${desc}.sql"
    $destination = Join-Path $migrationPath $newFile

    Write-Output "Creating $newFile"

    Get-Content $file.FullName -Raw | Set-Content $destination

    $currentTime = $currentTime.AddSeconds(1)
}

Write-Output "===== Dependency-Sorted Flyway Generation Completed ====="