Write-Output "===== ENTERPRISE FLYWAY CONVERSION STARTED ====="

$basePath = Get-Location  
$migrationPath = Join-Path $basePath "migrations"

# ================= CLEAN OUTPUT =================
if (Test-Path $migrationPath) {
    Remove-Item -Recurse -Force $migrationPath
}

New-Item -ItemType Directory -Path $migrationPath | Out-Null

# ================= STORAGE =================
$schemas = New-Object System.Collections.Generic.HashSet[string]
$types   = New-Object System.Collections.Generic.HashSet[string]

$fileOrder = @(
    "V1__schemas.sql",
    "V2__types.sql",
    "V3__xml_schema_collections.sql",
    "V4__tables.sql",
    "V5__primary_keys.sql",
    "V6__foreign_keys.sql",
    "V7__constraints.sql",
    "V8__indexes.sql",
    "V9__functions.sql",
    "V10__views.sql",
    "V11__procedures.sql",
    "V12__triggers.sql"
)

$files = @{}

foreach ($f in $fileOrder) {
    $files[$f] = ""
}

function Add-ContentSafe($key, $text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    $clean = $text.Trim()

    if (-not $files.ContainsKey($key)) {
        $files[$key] = ""
    }

    $files[$key] += "`r`n$clean`r`nGO`r`n"
}

# ================= LOAD SQL FILES =================
$allFiles = Get-ChildItem -Path $basePath -Recurse -Filter *.sql -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch "\\migrations\\" }

$executionList = @()

foreach ($file in $allFiles) {

    if (Test-Path $file.FullName) {
        $executionList += $file.Name
    }
    else {
        Write-Host "Skipping missing file: $($file.FullName)"
    }
}
 {

    $content = Get-Content $file.FullName -Raw

    # ================= SCHEMAS =================
    $schemaMatches = [regex]::Matches($content, "(?:\[(\w+)\]\.|\b(\w+)\.)")

    foreach ($m in $schemaMatches) {
        $schema = $m.Groups[1].Value
        if (-not $schema) { $schema = $m.Groups[2].Value }

        if ($schema -and $schema -notmatch "^(dbo|sys|INFORMATION_SCHEMA)$") {
            $schemas.Add($schema) | Out-Null
        }
    }

    # ================= TYPES =================
    $typeMatches = [regex]::Matches($content, "\[(\w+)\]\.\[(\w+)\]")

    foreach ($m in $typeMatches) {

        $schema = $m.Groups[1].Value
        $name   = $m.Groups[2].Value

        if ($schema -eq "dbo") {
            if ($name -notmatch "^(int|bigint|smallint|tinyint|bit|nvarchar|varchar|datetime|decimal|float|uniqueidentifier)$") {
                $types.Add("$schema.$name") | Out-Null
            }
        }
    }

    # ================= XML SCHEMA COLLECTION =================
    if ($content -match "CREATE\s+XML\s+SCHEMA\s+COLLECTION") {

        $matches = [regex]::Matches(
            $content,
            "CREATE\s+XML\s+SCHEMA\s+COLLECTION\s+[\[\]\w\.]+\s+AS\s+N?'[\s\S]*?'",
            "IgnoreCase"
        )

        foreach ($match in $matches) {
            Add-ContentSafe "V3__xml_schema_collections.sql" $match.Value
        }
    }

    # ================= CLASSIFICATION =================
    if ($file.FullName -match "01_Tables") {

        Add-ContentSafe "V4__tables.sql" $content

        if ($content -match "PRIMARY\s+KEY") { Add-ContentSafe "V5__primary_keys.sql" $content }
        if ($content -match "FOREIGN\s+KEY") { Add-ContentSafe "V6__foreign_keys.sql" $content }
        if ($content -match "DEFAULT|CHECK") { Add-ContentSafe "V7__constraints.sql" $content }
        if ($content -match "INDEX") { Add-ContentSafe "V8__indexes.sql" $content }
    }

    elseif ($file.FullName -match "04_Functions") {
        Add-ContentSafe "V9__functions.sql" ($content -replace "CREATE\s+FUNCTION", "CREATE OR ALTER FUNCTION")
    }

    elseif ($file.FullName -match "02_Views") {
        Add-ContentSafe "V10__views.sql" ($content -replace "CREATE\s+VIEW", "CREATE OR ALTER VIEW")
    }

    elseif ($file.FullName -match "03_Procedures") {
        Add-ContentSafe "V11__procedures.sql" ($content -replace "CREATE\s+PROCEDURE", "CREATE OR ALTER PROCEDURE")
    }

    elseif ($file.FullName -match "05_Triggers") {
        Add-ContentSafe "V12__triggers.sql" ($content -replace "CREATE\s+TRIGGER", "CREATE OR ALTER TRIGGER")
    }
}

# ================= SCHEMAS OUTPUT =================
foreach ($s in ($schemas | Select-Object -Unique)) {

    if ([string]::IsNullOrWhiteSpace($s)) { continue }

    $files["V1__schemas.sql"] += @"
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '$s')
BEGIN
    EXEC('CREATE SCHEMA [$s]');
END
GO
"@
}

# ================= TYPES OUTPUT =================
foreach ($t in ($types | Select-Object -Unique)) {

    $parts = $t.Split('.')
    if ($parts.Count -ne 2) { continue }

    $schema = $parts[0]
    $name   = $parts[1]

    $files["V2__types.sql"] += @"
IF TYPE_ID('$schema.$name') IS NULL
BEGIN
    EXEC('CREATE TYPE [$schema].[$name] FROM NVARCHAR(50)');
END
GO
"@
}

# ================= WRITE FILES =================
$keys = @($files.Keys)

foreach ($k in $keys) {

    $files[$k] = $files[$k] -replace "GO\s*IF", "GO`r`nIF"
    $files[$k] = $files[$k] -replace "GOIF", "GO`r`nIF"

    $path = Join-Path $migrationPath $k
    Set-Content -Path $path -Value $files[$k] -Encoding UTF8

    Write-Output "Created $k"
}

Write-Output "===== ENTERPRISE FLYWAY CONVERSION COMPLETED ====="