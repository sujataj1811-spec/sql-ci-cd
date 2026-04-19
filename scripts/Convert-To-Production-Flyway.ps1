Write-Output "===== ENTERPRISE FLYWAY CONVERSION STARTED ====="

$basePath = Get-Location
$migrationPath = Join-Path $basePath "migrations"

# Clean output
if (Test-Path $migrationPath) {
    Remove-Item -Recurse -Force $migrationPath
}
New-Item -ItemType Directory -Path $migrationPath | Out-Null

# ================= STORAGE =================
$schemas = New-Object System.Collections.Generic.HashSet[string]
$types   = New-Object System.Collections.Generic.HashSet[string]

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
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $files[$key] += "`r`n" + $text + "`r`nGO`r`n"
}

# ================= LOAD FILES =================
$allFiles = Get-ChildItem -Recurse -Filter *.sql

foreach ($file in $allFiles) {

    $content = Get-Content $file.FullName -Raw

    # ================= SAFE SCHEMA DETECTION =================
    # ONLY real SQL object patterns: [schema].[object]
    $schemaMatches = [regex]::Matches($content, "\[\s*(\w+)\s*\]\.\[")

    foreach ($m in $schemaMatches) {
        $schemas.Add($m.Groups[1].Value) | Out-Null
    }

    # ================= SAFE TYPE DETECTION =================
    $typeMatches = [regex]::Matches($content, "\[\s*(\w+)\s*\]\.\[\s*(\w+)\s*\]")

    foreach ($m in $typeMatches) {

        $schema = $m.Groups[1].Value
        $name   = $m.Groups[2].Value

        # only user-defined types
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
        Add-ContentSafe "R__views.sql" ($content -replace "CREATE\s+VIEW", "CREATE OR ALTER VIEW")
    }

    elseif ($file.FullName -match "03_Procedures") {
        Add-ContentSafe "R__procedures.sql" ($content -replace "CREATE\s+PROCEDURE", "CREATE OR ALTER PROCEDURE")
    }

    elseif ($file.FullName -match "04_Functions") {
        Add-ContentSafe "R__functions.sql" ($content -replace "CREATE\s+FUNCTION", "CREATE OR ALTER FUNCTION")
    }

    elseif ($file.FullName -match "05_Triggers") {
        Add-ContentSafe "R__triggers.sql" ($content -replace "CREATE\s+TRIGGER", "CREATE OR ALTER TRIGGER")
    }
}

# ================= SCHEMAS OUTPUT =================
foreach ($s in $schemas) {

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
foreach ($t in $types) {

    if ([string]::IsNullOrWhiteSpace($t)) { continue }

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

Write-Output "===== ENTERPRISE FLYWAY CONVERSION COMPLETED ====="