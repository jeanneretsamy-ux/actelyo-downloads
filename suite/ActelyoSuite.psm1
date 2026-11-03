Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Read-SuiteJson([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Write-SuiteJson($Value, [string]$Path) {
    $json = $Value | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}
function Assert-SuiteItem($Item) {
    if ($Item.id -notmatch '^[a-z0-9-]+$' -or $Item.file -ne [IO.Path]::GetFileName($Item.file) -or
        $Item.file -match '[:\\/]' -or $Item.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        [double]$Item.bytes -le 0 -or [double]$Item.bytes -ne [math]::Floor([double]$Item.bytes)) { throw 'Entree de catalogue invalide.' }
    $parts = @(if ($Item.PSObject.Properties['parts']) { $Item.parts } else { $Item })
    if ($parts.Count -lt 1) { throw 'Aucune source de telechargement.' }
    foreach ($part in $parts) {
        $url = [uri]$part.url
        if ($url.Scheme -ne 'https' -or $url.UserInfo -or $url.Host -notin @('github.com','huggingface.co') -or
            $part.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [double]$part.bytes -le 0) { throw 'Source de telechargement invalide.' }
    }
    if (($parts | Measure-Object bytes -Sum).Sum -ne $Item.bytes) { throw 'La taille des parties ne correspond pas au fichier.' }
}
function Get-SuiteRegistrations {
    $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    @(Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] })
}
function Find-SuiteInstallation($Definition, $Registrations) {
    $matches = @($Registrations | Where-Object { $_.DisplayName -match $Definition.registryPattern })
    if ($matches.Count -gt 1) { throw ('Plusieurs installations correspondent a '+$Definition.id+'. Aucun choix automatique.') }
    if ($matches.Count -eq 0) { return $null }
    $entry = $matches[0]
    if (-not $entry.PSObject.Properties['InstallLocation'] -or -not $entry.InstallLocation) { throw ('Dossier inconnu pour '+$Definition.id) }
    $directory = [IO.Path]::GetFullPath($entry.InstallLocation)
    $exe = $null
    foreach ($name in $Definition.executables) {
        $candidate = Join-Path $directory $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $exe = $candidate; break }
    }
    if ($Definition.executables.Count -gt 0 -and -not $exe) { throw ('Executable attendu absent pour '+$Definition.id) }
    if ($Definition.PSObject.Properties['requiredFiles']) {
        foreach ($file in $Definition.requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $directory $file) -PathType Leaf)) { throw ('Fichier absent : '+$Definition.id+'/'+$file) }
        }
    }
    [pscustomobject]@{ id=$Definition.id; version=$entry.DisplayVersion; directory=$directory; executable=$exe }
}
function Compare-SuiteVersion([string]$Installed, [string]$Requested) {
    $a = $null; $b = $null
    if (-not [version]::TryParse($Installed,[ref]$a) -or -not [version]::TryParse($Requested,[ref]$b)) { throw 'Version non comparable, intervention manuelle requise.' }
    $a.CompareTo($b)
}
function Get-SuiteSpacePlan($Items, $Definitions, [string]$DownloadDirectory, [string]$InstallDirectory, [double]$HeadroomGiB) {
    $volumes = @{}
    [double]$downloadBytes = 0
    [double]$installBytes = 0
    foreach ($item in $Items) { $downloadBytes += [double]$item.bytes }
    foreach ($definition in $Definitions) { $installBytes += [double]$definition.reserveGiB * 1GB }
    $pairs = @()
    if ($downloadBytes -gt 0) { $pairs += @{Path=$DownloadDirectory;Bytes=$downloadBytes} }
    if ($InstallDirectory) { $pairs += @{Path=$InstallDirectory;Bytes=$installBytes} }
    foreach ($pair in $pairs) {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$pair.Path))
        if (-not $root -or $root.StartsWith('\\')) { throw 'Choisissez un disque local pour ce kit.' }
        if (-not $volumes.ContainsKey($root)) { $volumes[$root]=0.0 }
        $volumes[$root] += [double]$pair.Bytes
    }
    foreach ($root in $volumes.Keys) {
        $drive = New-Object IO.DriveInfo($root)
        $required = [long]($volumes[$root]+$HeadroomGiB*1GB)
        [pscustomobject]@{ volume=$root; requiredBytes=$required; freeBytes=$drive.AvailableFreeSpace; ok=($drive.AvailableFreeSpace -ge $required) }
    }
}
function Receive-SuiteItem($Item, [string]$Directory) {
    Assert-SuiteItem $Item
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $target = Join-Path ([IO.Path]::GetFullPath($Directory)) $Item.file
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target).Length -eq $Item.bytes -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $Item.sha256) { return $target }
        throw ('Fichier different deja present : '+$target+'. Deplacez-le avant de recommencer.')
    }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(2)
    $partial = $target+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    $output = $null
    try {
        $output = [IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $parts = @(if ($Item.PSObject.Properties['parts']) { $Item.parts } else { $Item })
        foreach ($part in $parts) {
            Write-Host ('Telechargement verifie : '+$Item.name+' ('+$part.bytes+' octets)')
            $stream = $client.GetStreamAsync([uri]$part.url).GetAwaiter().GetResult()
            $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            $buffer = New-Object byte[] (1MB)
            [long]$received = 0
            try {
                while (($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $received += $count
                    if ($received -gt $part.bytes) { throw 'Taille du telechargement depassee.' }
                    $hash.AppendData($buffer,0,$count); $output.Write($buffer,0,$count)
                }
                $digest = ([BitConverter]::ToString($hash.GetHashAndReset())).Replace('-','')
                if ($received -ne $part.bytes -or $digest -ne $part.sha256) { throw ('Partie incorrecte : '+$Item.id) }
            } finally { $stream.Dispose(); $hash.Dispose() }
        }
        $output.Dispose(); $output=$null
        if ((Get-Item -LiteralPath $partial).Length -ne $Item.bytes -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Item.sha256) { throw 'Empreinte finale incorrecte.' }
        Move-Item -LiteralPath $partial -Destination $target
        return $target
    } finally {
        if ($output) { $output.Dispose() }; $client.Dispose()
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}
Export-ModuleMember -Function *-Suite*
