Write-Output "===== DEPENDENCY ENGINE v3 STARTED ====="

$basePath = Get-Location
$sqlFiles = Get-ChildItem -Path $basePath -Recurse -Filter "*.sql" | Where-Object { $_.FullName -notmatch "migrations" }

# ================= STORAGE =================
$nodes = @{}
$graph = @{}
$inDegree = @{}

# ================= HELPERS =================
function Get-ObjectName {
    param($line)

    if ($line -match "(FROM|JOIN|UPDATE|INTO|EXEC|CALL)\s+([\[\]\w\.]+)") {
        return $matches[2] -replace "\[|\]", ""
    }
    return $null
}

# ================= BUILD GRAPH =================
foreach ($file in $sqlFiles) {

    $content = Get-Content $file.FullName -Raw
    $fileName = $file.Name

    if (-not $graph.ContainsKey($fileName)) {
        $graph[$fileName] = @()
    }

    $inDegree[$fileName] = 0

    # detect dependencies
    $matches = [regex]::Matches($content, "(FROM|JOIN|UPDATE|INTO|EXEC|CALL)\s+([\[\]\w\.]+)", "IgnoreCase")

    foreach ($m in $matches) {

        $dep = $m.Groups[2].Value -replace "\[|\]", ""

        foreach ($target in $sqlFiles) {

            if ($target.Name -ne $fileName -and $target.Name -like "*$dep*") {

                $graph[$target.Name] += $fileName

                if (-not $inDegree.ContainsKey($fileName)) {
                    $inDegree[$fileName] = 0
                }

                $inDegree[$fileName]++
            }
        }
    }
}

# ================= TOPOLOGICAL SORT =================
$queue = New-Object System.Collections.Queue

foreach ($node in $inDegree.Keys) {
    if ($inDegree[$node] -eq 0) {
        $queue.Enqueue($node)
    }
}

$sorted = @()

while ($queue.Count -gt 0) {

    $current = $queue.Dequeue()
    $sorted += $current

    foreach ($neighbor in $graph[$current]) {

        $inDegree[$neighbor]--

        if ($inDegree[$neighbor] -eq 0) {
            $queue.Enqueue($neighbor)
        }
    }
}

# ================= OUTPUT =================
Write-Output "`n===== EXECUTION ORDER (FIXED) ====="

$index = 1
foreach ($file in $sorted) {
    Write-Output "$index. $file"
    $index++
}

# ================= SAVE ORDER =================
$sorted | Out-File "$basePath\execution-order.txt"

Write-Output "`n===== DEPENDENCY ENGINE v3 COMPLETED ====="