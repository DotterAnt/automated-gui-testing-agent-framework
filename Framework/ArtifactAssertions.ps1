function Assert-TextContains {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result,
          [Parameter(Mandatory)] [string[]] $Expected,
          [string] $Message='Readback must contain every expected text fragment.')
    $validSource=($Result.command -eq 'read-pdf' -or
        ($Result.command -eq 'read' -and $Result.data.textSource -in @('ValuePattern','TextPattern')))
    Assert-ExpectedResult -Condition ([bool]($Result.ok -and $validSource)) -Message "$Message Requires successful content readback, not an element name."
    if (-not $Expected.Count -or @($Expected | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count) { throw 'Expected text fragments must not be empty.' }
    $text=([string]$Result.data.text).Replace("`r`n","`n").Replace("`r","`n")
    foreach ($fragment in $Expected) {
        $normalized=$fragment.Replace("`r`n","`n").Replace("`r","`n")
        Assert-ExpectedResult -Condition ($text.IndexOf($normalized,[StringComparison]::Ordinal) -ge 0) -Message "$Message Missing fragment: $fragment"
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
