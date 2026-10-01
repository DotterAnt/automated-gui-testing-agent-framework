param([ValidateRange(3,20)] [int]$Count=6,[string]$OutFile)
$ErrorActionPreference='Stop'
# Read-only probe: no execution policy, profile, security or global setting edits.
$samples=@()
foreach ($exe in @('powershell.exe','pwsh.exe')) {
    $command=Get-Command $exe -ErrorAction SilentlyContinue
    if (-not $command) {continue}
    for ($i=0;$i -lt $Count;$i++) {
        $modes=if ($i%2) {@('NoProfileBypass','NoProfileDefault','ProfileDefault')} else {@('ProfileDefault','NoProfileDefault','NoProfileBypass')}
        foreach ($mode in $modes) {
            # Encoded literals contain only this read-only fixed probe.
            $code='$ProgressPreference="SilentlyContinue"; $w=[Diagnostics.Stopwatch]::StartNew(); $null=Get-ChildItem -LiteralPath $env:TEMP; [Console]::WriteLine((@{commandMs=$w.Elapsed.TotalMilliseconds;version=$PSVersionTable.PSVersion.ToString();policy=[string](Get-ExecutionPolicy)} | ConvertTo-Json -Compress))'
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$command.Source
            $flags=if ($mode -eq 'NoProfileBypass') {'-NoProfile -ExecutionPolicy Bypass'} elseif ($mode -eq 'NoProfileDefault') {'-NoProfile'} else {''}
            $info.Arguments=$flags+' -EncodedCommand '+$encoded
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            # -ExecutionPolicy on this probe's parent is inherited via an env
            # variable. Remove only the child's override to measure defaults.
            $info.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
            $watch=[Diagnostics.Stopwatch]::StartNew();$process=[Diagnostics.Process]::Start($info)
            try {
                $errors=$process.StandardError.ReadToEndAsync();$output=$process.StandardOutput.ReadToEnd()
                $process.WaitForExit();$elapsed=$watch.Elapsed.TotalMilliseconds
                if ($process.ExitCode -ne 0) {throw "Probe failed: $($errors.GetAwaiter().GetResult())"}
                $value=@($output -split '\r?\n' | Where-Object {$_ -match '^\{'} | ForEach-Object {$_ | ConvertFrom-Json})[-1]
                if (-not $value.version) {throw 'Probe output was changed by the shell profile.'}
                $samples+=,@{exe=$exe;mode=$mode;wallMs=[Math]::Round($elapsed,2);commandMs=[Math]::Round($value.commandMs,2);effectivePolicy=$value.policy;version=$value.version}
            } finally {$process.Dispose()}
        }
    }
}
$result=@{samples=$samples;policies=@(Get-ExecutionPolicy -List | Select-Object @{Name='scope';Expression={[string]$_.Scope}},@{Name='policy';Expression={[string]$_.ExecutionPolicy}});
    note='Read-only Get-ChildItem probe. Wall includes a fresh OS process, profile/host startup, cmdlet loading and JSON output; commandMs excludes earlier startup and final formatting. Run directly in the test VM, then compare with the agent shell-tool duration. No global policy/config changes.'}
if ($OutFile) {$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8}
$result | ConvertTo-Json -Depth 6 -Compress
