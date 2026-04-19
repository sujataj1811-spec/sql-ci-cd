Write-Output "===== AUTO FLYWAY CONVERSION (SCHEMA + TYPES INCLUDED) ====="

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
    "V2_1__xml_schema_collections.sql" = ""
    "V3__tables.sql" = ""
    "V5__foreign_keys.sql" = ""
    "V6__constraints.sql" = ""
    "V7__indexes.sql" = ""
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

# ================= LOAD ALL SQL FILES =================
$allFiles = Get-ChildItem -Recurse -Filter *.sql

foreach ($file in $allFiles) {

    $content = Get-Content $file.FullName -Raw

    # ================= EXTRACT SCHEMAS =================
    $schemaMatches = [regex]::Matches($content, "\b(\w+)\.(\w+)")
    foreach ($m in $schemaMatches) {
        $schemas += $m.Groups[1].Value
    }

    # ================= EXTRACT TYPES (STRICT SAFE) =================
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

    # ================= DEBUG =================
    if ($content -match "XML") {
        Write-Output "XML keyword found in $($file.FullName)"
    }

    # ================= XML SCHEMA COLLECTION EXTRACTION =================
    if ($content -match "CREATE\s+XML\s+SCHEMA\s+COLLECTION") {

        Write-Output "✔ XML Schema detected in $($file.Name)"

        $xmlMatch = [regex]::Match(
            $content,
            "CREATE\s+XML\s+SCHEMA\s+COLLECTION[\s\S]+?GO",
            "IgnoreCase"
        )

        if ($xmlMatch.Success) {
            Add-ContentSafe "V2_1__xml_schema_collections.sql" $xmlMatch.Value
        }
    }

    # ================= CLASSIFY FILE =================
    if ($file.FullName -match "01_Tables") {

        Add-ContentSafe "V3__tables.sql" $content

        if ($content -match "FOREIGN\s+KEY") {
            Add-ContentSafe "V5__foreign_keys.sql" $content
        }

        if ($content -match "DEFAULT|CHECK") {
            Add-ContentSafe "V6__constraints.sql" $content
        }

        if ($content -match "INDEX") {
            Add-ContentSafe "V7__indexes.sql" $content
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

# ================= BUILD SCHEMA FILE =================
$schemas = $schemas | Where-Object { $_ -ne "dbo" } | Select-Object -Unique

foreach ($s in $schemas) {
    $files["V1__schemas.sql"] += @"
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = '$s')
    EXEC('CREATE SCHEMA [$s]');
GO
"@
}

# ================= BUILD TYPES FILE =================
foreach ($t in $types | Select-Object -Unique) {

    $schema, $name = $t.Split('.')

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
    Set-Content $path $files[$k]
    Write-Output "Created $k"
}

Write-Output "===== AUTO CONVERSION COMPLETED ====="