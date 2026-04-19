Write-Output "===== AUTO FLYWAY CONVERSION (SAFE MODE) ====="

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

# Clean migrations
if (Test-Path $migrationPath) {
    Remove-Item -Recurse -Force $migrationPath
}
New-Item -ItemType Directory -Path $migrationPath | Out-Null

# ================= STORAGE =================
$schemas = @()
$types   = @()

$files = @{
    "V1__schemas.sql" = ""
    "V2__types.sql" = ""
    "V3__xml_schema_collections.sql" = ""
    "V4__tables.sql" = ""
    "V5__primary_keys.sql" = ""
    "V6__foreign_keys.sql" = ""
    "V7__constraints.sql" = ""
    "V8__indexes.sql" = ""
    "R__views.sql" = ""
    "R__procedures.sql" = ""
    "R__functions.sql" = ""
    "R__triggers.sql" = ""
}

function Add-ContentSafe($key, $text) {
    if ($text -and $text.Trim() -ne "") {
        $files[$key] += "`n$text`nGO`n"
    }
}

# ================= LOAD FILES =================
$allFiles = Get-ChildItem -Recurse -Filter *.sql

foreach ($file in $allFiles) {

    $content = Get-Content $file.FullName -Raw

    # ================= SCHEMA EXTRACTION (SAFE) =================
    $schemaMatches = [regex]::Matches($content, "\b(\w+)\.\w+")

    foreach ($m in $schemaMatches) {
        $schema = $m.Groups[1].Value

        if ($schema -and $schema -notmatch "^(dbo|sys|INFORMATION_SCHEMA)$") {
            $schemas += $schema
        }
    }

    # ================= TYPE EXTRACTION =================
    $typeMatches = [regex]::Matches($content, "\[(\w+)\]\.\[(\w+)\]")

    foreach ($m in $typeMatches) {
        $schema = $m.Groups[1].Value
        $name   = $m.Groups[2].Value

        if ($schema -eq "dbo") {
            $types += "$schema.$name"
        }
    }

    # ================= XML SCHEMA COLLECTION =================
    if ($content -match "CREATE\s+XML\s+SCHEMA\s+COLLECTION") {

        Write-Output "XML Schema found in $($file.Name)"

        $xmlMatches = [regex]::Matches(
            $content,
            "CREATE\s+XML\s+SCHEMA\s+COLLECTION\s+[\[\]\w\.]+\s+AS\s+N?'[\s\S]*?'",
            "IgnoreCase"
        )

        foreach ($m in $xmlMatches) {
            Add-ContentSafe "V3__xml_schema_collections.sql" $m.Value
        }
    }

    # ================= TABLES =================
    if ($file.FullName -match "01_Tables") {

        Add-ContentSafe "V4__tables.sql" $content

        if ($content -match "PRIMARY\s+KEY") {
            Add-ContentSafe "V5__primary_keys.sql" $content
        }

        if ($content -match "FOREIGN\s+KEY") {
            Add-ContentSafe "V6__foreign_keys.sql" $content
        }

        if ($content -match "DEFAULT|CHECK") {
            Add-ContentSafe "V7__constraints.sql" $content
        }

        if ($content -match "INDEX") {
            Add-ContentSafe "V8__indexes.sql" $content
        }
    }

    elseif ($file.FullName -match "02_Views") {
        $c = $content -replace "CREATE\s+VIEW", "CREATE OR ALTER VIEW"
        Add-ContentSafe "R__views.sql" $c
    }

    elseif ($file.FullName -match "03_Procedures") {
        $c = $content -replace "CREATE\s+PROCEDURE", "CREATE OR ALTER PROCEDURE"
        Add-ContentSafe "R__procedures.sql" $c
    }

    elseif ($file.FullName -match "04_Functions") {
        $c = $content -replace "CREATE\s+FUNCTION", "CREATE OR ALTER FUNCTION"
        Add-ContentSafe "R__functions.sql" $c
    }

    elseif ($file.FullName -match "05_Triggers") {
        $c = $content -replace "CREATE\s+TRIGGER", "CREATE OR ALTER TRIGGER"
        Add-ContentSafe "R__triggers.sql" $c
    }
}

# ===== BUILD SCHEMA FILE =====
$schemas = $schemas |
    Where-Object { $_ -notmatch "^(dbo|sys|INFORMATION_SCHEMA)$" } |
    Select-Object -Unique

foreach ($s in $schemas) {

    if (-not $s) { continue }

    $files["V1__schemas.sql"] += @"
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = '$s')
BEGIN
    EXEC('CREATE SCHEMA [$s]');
END
GO

"@
}

# ================= BUILD TYPES =================
foreach ($t in ($types | Select-Object -Unique)) {

    if (-not $t) { continue }

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
foreach ($k in $files.Keys) {

    $path = Join-Path $migrationPath $k
    Set-Content -Path $path -Value $files[$k]

    Write-Output "Created $k"
}

Write-Output "===== AUTO CONVERSION COMPLETED ====="