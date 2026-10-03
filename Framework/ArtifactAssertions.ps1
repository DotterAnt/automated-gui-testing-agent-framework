. (Join-Path $PSScriptRoot 'ImageAssertions.ps1')

function Assert-TextContains {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $Result,
          [Parameter(Mandatory)] [string[]] $Expected,
          [string] $Message='Readback must contain every expected text fragment.')
    process {
        $validSource=($Result.command -eq 'read-pdf' -or
            ($Result.command -eq 'read' -and $Result.data.textSource -in @('ValuePattern','TextPattern','Win32Edit')))
        Assert-ExpectedResult -Condition ([bool]($Result.ok -and $validSource)) -Message "$Message Requires successful content readback, not an element name."
        if (-not $Expected.Count -or @($Expected | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count) { throw 'Expected text fragments must not be empty.' }
        $text=([string]$Result.data.text).Replace("`r`n","`n").Replace("`r","`n")
        foreach ($fragment in $Expected) {
            $normalized=$fragment.Replace("`r`n","`n").Replace("`r","`n")
            Assert-ExpectedResult -Condition ($text.IndexOf($normalized,[StringComparison]::Ordinal) -ge 0) -Message "$Message Missing fragment: $fragment"
        }
    }
}

function Read-AGTAArtifactBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateRange(1,1048576)] [int] $Count = 4096,
        [ValidateRange(0,2147483647)] [long] $Offset = 0,
        [ValidateRange(0,60000)] [int] $TimeoutMs = 2000,
        [IO.FileShare] $Share = [IO.FileShare]::ReadWrite
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $stream = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $Share)
            [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            $bytes = New-Object byte[] $Count
            $read = 0
            while ($read -lt $Count) {
                $n = $stream.Read($bytes, $read, $Count - $read)
                if ($n -eq 0) { throw "Artifact has fewer than $Count requested bytes at offset $Offset." }
                $read += $n
            }
            return ,$bytes
        }
        catch { if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { throw } }
        finally { if ($stream) { $stream.Dispose() } }
        Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Max(1, $TimeoutMs - $watch.ElapsedMilliseconds)))
    } while ($true)
}

function Assert-ArtifactPrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path,
          [Parameter(Mandatory)] [byte[]] $ExpectedBytes,
          [string] $Message = 'Artifact must have the expected prefix.',
          [int] $TimeoutMs = 2000)
    if (-not $ExpectedBytes.Length) { throw 'ExpectedBytes must not be empty.' }
    try {
        $actual = Read-AGTAArtifactBytes -Path $Path -Count $ExpectedBytes.Length -TimeoutMs $TimeoutMs
        $matches = [Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($ExpectedBytes)
    }
    catch { Assert-ExpectedResult -Condition $false -Message "$Message $($_.Exception.Message)"; return }
    Assert-ExpectedResult -Condition $matches -Message $Message
}

function Read-AGTAZipText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string[]]$EntryPattern,
        [ValidateRange(1,16777216)] [int]$MaxBytes=1048576,
        [ValidateRange(0,60000)] [int]$TimeoutMs=2000)
    # Generic read-only archive inspection. No application APIs or synthetic outputs.
    Add-Type -AssemblyName System.IO.Compression
    if (-not $EntryPattern.Count -or @($EntryPattern | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count) { throw 'EntryPattern must not be empty.' }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $stream=$null; $archive=$null
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
            $items=@(); $total=0
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName.EndsWith('/') -or -not @($EntryPattern | Where-Object {$entry.FullName -like $_}).Count) { continue }
                if ($entry.Length -gt $MaxBytes-$total) { throw [IO.InvalidDataException]::new('Selected ZIP text exceeds MaxBytes; narrow EntryPattern.') }
                $input=$null; $buffer=$null
                try {
                    $input=$entry.Open(); $buffer=New-Object IO.MemoryStream
                    $chunk=New-Object byte[] 8192
                    while (($n=$input.Read($chunk,0,$chunk.Length)) -gt 0) {
                        $total+=$n
                        if ($total -gt $MaxBytes) { throw [IO.InvalidDataException]::new('Selected ZIP text exceeds MaxBytes; narrow EntryPattern.') }
                        $buffer.Write($chunk,0,$n)
                    }
                    $buffer.Position=0
                    $reader=New-Object IO.StreamReader($buffer,[Text.UTF8Encoding]::new($false,$true),$true,1024,$true)
                    try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
                    $items+=,[pscustomobject]@{name=$entry.FullName;text=$text}
                } finally { if ($input) {$input.Dispose()}; if ($buffer) {$buffer.Dispose()} }
            }
            if (-not $items.Count) { throw [IO.InvalidDataException]::new('No ZIP entries match EntryPattern.') }
            return $items
        }
        catch {
            # Retry transient output/file locks only. Corrupt content and bounds
            # are real assertion failures, not reasons to spend the full timeout.
            if ($_.Exception -isnot [IO.IOException] -or $_.Exception -is [IO.InvalidDataException] -or $watch.ElapsedMilliseconds -ge $TimeoutMs) { throw }
        }
        finally { if ($archive) {$archive.Dispose()}; if ($stream) {$stream.Dispose()} }
        Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(100,$TimeoutMs-$watch.ElapsedMilliseconds)))
    } while ($true)
}

function Assert-ZipTextContains {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string[]]$EntryPattern,
        [Parameter(Mandatory)] [string[]]$Expected,
        [ValidateRange(1,2147483647)] [int]$ExpectedEntryCount,
        [ValidateRange(1,16777216)] [int]$MaxBytes=1048576,
        [ValidateRange(0,60000)] [int]$TimeoutMs=2000,
        [string]$Message='Archive text must contain every expected fragment.')
    if (-not $Expected.Count -or @($Expected | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count) { throw 'Expected text fragments must not be empty.' }
    try { $entries=@(Read-AGTAZipText -Path $Path -EntryPattern $EntryPattern -MaxBytes $MaxBytes -TimeoutMs $TimeoutMs) }
    catch { Assert-ExpectedResult -Condition $false -Message "$Message $($_.Exception.Message)"; return }
    if ($PSBoundParameters.ContainsKey('ExpectedEntryCount')) {
        Assert-ExpectedResult -Condition ($entries.Count -eq $ExpectedEntryCount) -Message "$Message Expected $ExpectedEntryCount matching entries, found $($entries.Count)."
    }
    # Match within an actual entry, never a fragment fabricated across boundaries.
    $texts=@($entries | ForEach-Object {([string]$_.text).Replace("`r`n","`n").Replace("`r","`n")})
    foreach ($fragment in $Expected) {
        $normalized=$fragment.Replace("`r`n","`n").Replace("`r","`n")
        $found=@($texts | Where-Object {$_.IndexOf($normalized,[StringComparison]::Ordinal) -ge 0}).Count -gt 0
        Assert-ExpectedResult -Condition $found -Message "$Message Missing fragment: $fragment"
    }
}
