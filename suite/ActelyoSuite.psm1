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
    $location = if ($entry.PSObject.Properties['InstallLocation']) { $entry.InstallLocation } else { $null }
    if (-not $location -and $Definition.PSObject.Properties['registryIconFallback'] -and $Definition.registryIconFallback -and $entry.PSObject.Properties['DisplayIcon']) {
        # electron-builder records the install folder outside the Uninstall key.
        # Its registered executable icon provides an exact, verifiable path.
        $icon = [string]$entry.DisplayIcon
        $candidate = $null
        if ($icon -match '^"([^\"]+)"(?:,\s*-?\d+)?$') { $candidate=$Matches[1] }
        elseif ($icon -match '^([^\"]+?)(?:,\s*-?\d+)?$') { $candidate=$Matches[1] }
        if ($candidate -and [IO.Path]::IsPathRooted($candidate) -and [IO.Path]::GetFileName($candidate) -in $Definition.executables -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $location=[IO.Path]::GetDirectoryName($candidate) }
    }
    if (-not $location) { throw ('Dossier inconnu pour '+$Definition.id) }
    $directory = [IO.Path]::GetFullPath($location)
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
    $parsed = @()
    foreach ($text in @($Installed,$Requested)) {
        if ($text -notmatch '^(\d+(?:\.\d+){1,3})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$') { throw 'Version non comparable, intervention manuelle requise.' }
        $core=$Matches[1];$pre=if($Matches[2]){$Matches[2]}else{''};$numeric=$null
        if(-not [version]::TryParse($core,[ref]$numeric)){throw 'Version non comparable, intervention manuelle requise.'}
        foreach($identifier in @($pre -split '\.')){if($identifier -match '^\d+$' -and $identifier.Length -gt 1 -and $identifier.StartsWith('0')){throw 'Prerelease numerique invalide.'}}
        $parsed+=@{core=$numeric;pre=$pre}
    }
    $order=$parsed[0].core.CompareTo($parsed[1].core)
    if($order -ne 0){return $order}
    if($parsed[0].pre -ceq $parsed[1].pre){return 0}
    if(-not $parsed[0].pre){return 1}
    if(-not $parsed[1].pre){return -1}
    $a=@($parsed[0].pre -split '\.');$b=@($parsed[1].pre -split '\.')
    for($i=0;$i -lt [math]::Min($a.Count,$b.Count);$i++){
        $aNumeric=$a[$i] -match '^\d+$';$bNumeric=$b[$i] -match '^\d+$'
        if($aNumeric -and $bNumeric){
            $order=$a[$i].Length.CompareTo($b[$i].Length)
            if($order -eq 0){$order=[string]::CompareOrdinal($a[$i],$b[$i])}
        }elseif($aNumeric){$order=-1}elseif($bNumeric){$order=1}else{$order=[string]::CompareOrdinal($a[$i],$b[$i])}
        if($order -ne 0){return $order}
    }
    return $a.Count.CompareTo($b.Count)
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
function Get-SuiteInstallerArguments($Item, [string]$LogPath) {
    $kind = if ($Item.PSObject.Properties['installer']) { $Item.installer } else { 'inno' }
    switch ($kind) {
        'nsis' { return @('/S') }
        'inno' { return @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/LOG="'+$LogPath+'"')) }
        default { throw ('Type d''installateur non pris en charge : '+$kind) }
    }
}
function Receive-SuiteItem($Item, [string]$Directory, [Security.SecureString]$HuggingFaceToken=$null) {
    Assert-SuiteItem $Item
    if ($HuggingFaceToken -and ([uri]$Item.url).Host -ne 'huggingface.co') { throw 'Authentification reservee a Hugging Face.' }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $target = Join-Path ([IO.Path]::GetFullPath($Directory)) $Item.file
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target).Length -eq $Item.bytes -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $Item.sha256) { return $target }
        throw ('Fichier different deja present : '+$target+'. Deplacez-le avant de recommencer.')
    }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    if ($HuggingFaceToken) { $handler.AllowAutoRedirect=$false }
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(2)
    $partial = $target+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    $output = $null
    try {
        $output = [IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $parts = @(if ($Item.PSObject.Properties['parts']) { $Item.parts } else { $Item })
        foreach ($part in $parts) {
            Write-Host ('Telechargement verifie : '+$Item.name+' ('+$part.bytes+' octets)')
            $response=$null
            if ($HuggingFaceToken) {
                $uri=[uri]$part.url
                for($redirect=0;$redirect -le 8;$redirect++) {
                    if($uri.Scheme -ne 'https' -or $uri.UserInfo -or ($uri.Host -ne 'huggingface.co' -and -not $uri.Host.EndsWith('.huggingface.co') -and -not $uri.Host.EndsWith('.hf.co'))) { throw 'Redirection Hugging Face refusee.' }
                    $request=New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get,$uri)
                    try {
                        if($uri.Host -eq 'huggingface.co') {
                            $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($HuggingFaceToken)
                            try {$request.Headers.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr))}
                            finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
                        }
                        $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                    } finally {$request.Dispose()}
                    if([int]$response.StatusCode -in @(301,302,303,307,308)) {
                        $location=$response.Headers.Location
                        if(-not $location){$response.Dispose();throw 'Redirection sans destination.'}
                        $uri=New-Object uri($uri,$location);$response.Dispose();$response=$null
                        continue
                    }
                    if(-not $response.IsSuccessStatusCode){$status=[int]$response.StatusCode;$response.Dispose();throw ('Acces Hugging Face refuse ou indisponible (HTTP '+$status+'). Verifiez les droits du compte.')}
                    break
                }
                if(-not $response){throw 'Trop de redirections Hugging Face.'}
                $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            } else {$stream = $client.GetStreamAsync([uri]$part.url).GetAwaiter().GetResult()}
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
            } finally { $stream.Dispose(); $hash.Dispose();if($response){$response.Dispose()} }
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
