Write-Output "===== AUTO FLYWAY CONVERSION (SAFE MODE) ====="

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

# Clean migrations
if (Test-Path $migrationPath) {
    Remove-Item -Recurse -Force $migrationPath
}
New-Item -ItemType Directory -Path $migrationPath | Out-Null

# Storage
$schemas = @()
$types = @()
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
        $files[$key] += "`n" + $text + "`nGO`n"
    }
}

# ================= LOAD FILES =================
$allFiles = Get-ChildItem -Recurse -Filter *.sql

foreach ($file in $allFiles) {

    $content = Get-Content $file.FullName -Raw

    # ===== SCHEMA EXTRACT =====
    $schemaMatches = [regex]::Matches($content, "\b(\w+)\.(\w+)")
    foreach ($m in $schemaMatches) {
        $schemas += $m.Groups[1].Value
    }

    # ===== TYPE EXTRACT =====
    $typeMatches = [regex]::Matches($content, "\[\s*(\w+)\s*\]\.\[\s*(\w+)\s*\]")
    foreach ($m in $typeMatches) {

        $schema = $m.Groups[1].Value
        $name = $m.Groups[2].Value

        if ($schema -eq "dbo") {
            if ($name -notmatch "int|bigint|smallint|tinyint|nvarchar|varchar|datetime|bit|decimal|float|hierarchyid|uniqueidentifier") {
                $types += "$schema.$name"
            }
        }
    }

    # ===== XML SCHEMA COLLECTION =====
    if ($content -match "CREATE\s+XML\s+SCHEMA\s+COLLECTION") {

        Write-Output ("XML Schema found in " + $file.Name)

        $matches = [regex]::Matches(
            $content,
            "CREATE\s+XML\s+SCHEMA\s+COLLECTION\s+[\[\]\w\.]+\s+AS\s+N?'[\s\S]*?'",
            "IgnoreCase"
        )

        foreach ($match in $matches) {
            Add-ContentSafe "V3__xml_schema_collections.sql" $match.Value
        }
    }

    # ===== TABLES =====
    if ($file.FullName -match "01_Tables") {

        Add-ContentSafe "V4__tables.sql" $content

        # PRIMARY KEY
        if ($content -match "PRIMARY\s+KEY") {
            Add-ContentSafe "V5__primary_keys.sql" $content
        }

        # FOREIGN KEY
        if ($content -match "FOREIGN\s+KEY") {
            Add-ContentSafe "V6__foreign_keys.sql" $content
        }

        # DEFAULT / CHECK
        if ($content -match "DEFAULT|CHECK") {
            Add-ContentSafe "V7__constraints.sql" $content
        }

        # INDEX
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
$schemas = $schemas | Where-Object { $_ -ne "dbo" } | Select-Object -Unique

foreach ($s in $schemas) {
    $sql = "IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = '$s')`n"
    $sql += "EXEC('CREATE SCHEMA [$s]');`nGO`n"
    $files["V1__schemas.sql"] += $sql
}

# ===== BUILD TYPES FILE =====
foreach ($t in $types | Select-Object -Unique) {

    $parts = $t.Split('.')
    $schema = $parts[0]
    $name = $parts[1]

    $sql = "IF TYPE_ID('$schema.$name') IS NULL`n"
    $sql += "BEGIN`n"
    $sql += "    EXEC('CREATE TYPE [$schema].[$name] FROM NVARCHAR(50)');`n"
    $sql += "END`nGO`n"

    $files["V2__types.sql"] += $sql
}

# ===== WRITE FILES =====
foreach ($k in $files.Keys) {
    $path = Join-Path $migrationPath $k
    Set-Content -Path $path -Value $files[$k]
    Write-Output ("Created " + $k)
}

Write-Output "===== AUTO CONVERSION COMPLETED ====="