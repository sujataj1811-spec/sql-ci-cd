Write-Output "===== DEPENDENCY ENGINE v3 STARTED ====="

$basePath = Get-Location
$allFiles = Get-ChildItem -Recurse -Filter *.sql

# ================= GRAPH STORAGE =================
$nodes = @{}
$edges = @{}

function Add-Node($name) {
    if (-not $nodes.ContainsKey($name)) {
        $nodes[$name] = @{
            Name = $name
            DependsOn = New-Object System.Collections.Generic.HashSet[string]
        }
    }
}

function Add-Edge($from, $to) {
    Add-Node $from
    Add-Node $to
    $nodes[$from].DependsOn.Add($to) | Out-Null
}

# ================= PATTERNS =================
$functionPattern = "\b(\w+)\s*\("
$tablePattern    = "FROM\s+\[?(\w+)\]?\.\[?(\w+)\]?|JOIN\s+\[?(\w+)\]?\.\[?(\w+)\]?"
schemaPattern    = "\[?(\w+)\]?\.\["

# ================= ANALYZE FILES =================
foreach ($file in $allFiles) {

    $content = Get-Content $file.FullName -Raw
    $fileName = $file.Name

    Add-Node $fileName

    # ---------------- FUNCTIONS ----------------
    foreach ($m in [regex]::Matches($content, $functionPattern)) {
        $func = $m.Groups[1].Value

        if ($func -match "^dbo$|^sys$|^COUNT$|^SUM$|^GETDATE$") { continue }

        Add-Edge $fileName $func
    }

    # ---------------- TABLES / SCHEMAS ----------------
    foreach ($m in [regex]::Matches($content, $tablePattern)) {

        $schema = $m.Groups[1].Value
        $table  = $m.Groups[2].Value

        if ($schema -and $table) {
            Add-Edge $fileName "$schema.$table"
        }
    }

    # ---------------- SCHEMAS ----------------
    foreach ($m in [regex]::Matches($content, $schemaPattern)) {
        $schema = $m.Groups[1].Value
        if ($schema -and $schema -notmatch "dbo|sys|INFORMATION_SCHEMA") {
            Add-Edge $fileName $schema
        }
    }
}

# ================= TOPOLOGICAL SORT =================
$visited = @{}
$result = New-Object System.Collections.Generic.List[string]

function Visit($node) {

    if ($visited[$node] -eq "temp") {
        throw "CIRCULAR DEPENDENCY DETECTED: $node"
    }

    if ($visited[$node] -eq "perm") { return }

    $visited[$node] = "temp"

    foreach ($dep in $nodes[$node].DependsOn) {
        Visit $dep
    }

    $visited[$node] = "perm"
    $result.Add($node)
}

foreach ($node in $nodes.Keys) {
    if (-not $visited.ContainsKey($node)) {
        Visit $node
    }
}

# ================= OUTPUT PLAN =================
$planFile = Join-Path $basePath "dependency-plan.txt"
$result | Out-File $planFile -Encoding UTF8

Write-Output "===== DEPENDENCY PLAN GENERATED ====="
Write-Output "Output: dependency-plan.txt"