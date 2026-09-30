# Generated Script Contract

Start with `AUTHORING.md` and the template. GuiNavigation is the default; preserve an explicitly requested VisibleControls policy. Navigation and focused opaque input require per-command reason/evidence. Application hotkeys/Shortcut clearing require explicit AllowShortcuts authorization. A selector failure never authorizes a non-GUI route.

Generated testcase scripts must follow this contract so different agents and API providers produce comparable artifacts.

## Parameters

Every generated script must accept the first three parameters. It should also accept optional `-FrameworkRoot` for explicit runtime resolution:

```powershell
param(
    [string] $PotatoCliPath,
    [string] $TestCaseCsv,
    [string] $RunRoot,
    [string] $FrameworkRoot
)
```

Defaults are allowed. `-FrameworkRoot` is optional but recommended; generated scripts under `runs\<runId>\generated` can default it from `$PSScriptRoot`.

## Shared Runtime

Generated scripts must dot-source the shared runtime unless there is a concrete compatibility reason not to:

```powershell
$runtimePath = Join-Path -Path $FrameworkRoot -ChildPath 'Framework\GeneratedScriptRuntime.ps1'
. $runtimePath
$Context = Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot -RequireAssertions
```

Do not copy universal boilerplate into each generated script. The framework runtime already provides:

- `Invoke-PotatoJson`
- `Invoke-StepCommand`
- `Invoke-RecordedStep`
- `Assert-PotatoOk`, `Assert-PotatoFound`, and `Assert-FileWait`
- `Assert-ExpectedResult -Condition <bool> -Message <expected postcondition>`
- `Invoke-EvidenceScreenshot` and `Add-EvidencePath`
- `Register-OpenedProcess -StartResult $started` and `Register-CreatedExternalPath`
- `Invoke-TestCleanup`
- `Complete-AGTAGeneratedTest`

Generated scripts should contain testcase-specific paths, selectors, actions, assertions, and small local helpers only when they are specific to that application or testcase.

## Runtime Layout

The script must create these directories under `RunRoot` if they do not exist:

- `evidence`
- `logs`
- `results`

All screenshots, created files, JSON results, and command transcripts belong under `RunRoot`.

Files created only as evidence should stay under `RunRoot`. Files or application state created outside `RunRoot`, especially fixed-path outputs such as documents on the desktop or in temp folders, must be removed during cleanup unless the testcase explicitly requires them to remain.

## PoTATo Invocation

The script must call `potato-cli\potato.ps1` through the shared runtime helper:

```powershell
Invoke-PotatoJson -Command "observe" -Arguments @("-Depth", "2")
```

The runtime helper:

- run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <potato.ps1>`,
- parse the single JSON result,
- throw a clear error if the output is not JSON,
- save full command transcripts under an execution-specific file in `logs`, for example `potato-commands-<executionId>.jsonl`.

Each generated script run must create an `executionId` and a dedicated `commandLogPath`. Do not append every validation pass to one shared `potato-commands.jsonl`; repeated executions must be separable for analysis.

The final result JSON should keep command entries compact. A step `commands` item should contain fields like `index`, `command`, `arguments`, `ok`, `durationMs`, `logPath`, and `error`, not the full raw PoTATo response or full UI tree. The full parsed response belongs in the JSONL command log. `Invoke-StepCommand` and `Complete-AGTAGeneratedTest` already implement this shape.

GuiNavigation is enforced by default. `press-key` permits bounded Tab/ShiftTab/Enter/Escape/arrows with observed reason/evidence and checked application focus. Explicit VisibleControls rejects navigation too. Application hotkeys and Shortcut clearing require authorized AllowShortcuts; unreliable UIA or recovery is not permission. `type -TargetMode Focused` handles an observed opaque editor without compiling a private input backend.

Generated scripts should be optimized after they are functionally correct. Use specific waits instead of arbitrary sleeps, keep selectors as narrow as the application allows, avoid redundant `observe` or screenshot calls that are not used for evidence/debugging, and make expected dialogs/modals explicit instead of relying on timing.

Optimization must not remove required evidence or make failures harder to diagnose.

User/testcase interaction constraints override every fallback preference. A forbidden shortcut/clipboard operation is still forbidden inside a helper. Do not replace a required GUI route with process arguments, file association, an object model, or directly generated expected output. Record unavailable coverage as incomplete.

Start with CLI `help -Topic <command>` and the template. Keep desktop commands sequential. Use targeted queries before repeating broad `observe` calls. `select` queries elements; it does not select a dropdown item. A missing popup item may require opening its parent first. Use `click -Method Mouse` when exploration shows UIA Invoke does not cause the expected transition; observe before retrying a possibly completed action.

`type` accepts literal text and never uses the clipboard. `-Verify` reads UIA text without resending input. `-PreDelete` defaults to TextPattern selection plus Backspace; `-ClearMethod Shortcut` explicitly uses Ctrl+A and may only be used when permitted. Report an unsupported read/selection rather than silently substituting another route. `verified: null` means verification was not requested.

Use unique execution paths and `wait-file -MinBytes 1 -StableMs 500` before inspecting asynchronous output. Assert `conditionMet`, then validate required format/content; stability alone is not correctness. Before a GUI run, parse the script and validate paths/CSV. Compute path defaults in the body and avoid PowerShell automatic variable names. Preserve failed attempts for analysis.

For cleanup and recovery flows, avoid probing several nonexistent dialog buttons with long timeouts. First check whether a process/window or blocking dialog is actually present. If a prompt is possible but not expected, use short bounded checks and do not record expected misses as failures.

## Step Results

Each CSV row maps to one final step result object:

```json
{
  "stepIndex": 1,
  "action": "Open Paint",
  "expectedResult": "Paint opened",
  "status": "PASS",
  "evidence": [],
  "commands": [],
  "error": null
}
```

Allowed statuses:

- `PASS`
- `FAIL`
- `SKIPPED`

## Final JSON

New scripts must initialize with `-RequireAssertions`. `Invoke-RecordedStep` then requires a recorded postcondition and adds `assertions` to each result. `Assert-PotatoFound` and `Assert-FileWait` record assertions; `Assert-PotatoOk` checks command execution and does not count. Use `Assert-ExpectedResult` to compare actual content with expected values. Screenshot capture alone is not an assertion. The author must still choose checks that prove the CSV requirement.

The runtime attempts a failure screenshot before cleanup and preserves the original error if capture fails. Explicitly mark dependent rows `SKIPPED` after a failed prerequisite. Final `ok` requires each original row exactly once with its original action/expectation, all rows passing, recorded assertions when required, and successful cleanup. `-AllowSkipped` remains accepted for compatibility but no longer makes skipped work pass. Assertions default on. The template emits JSON and exits with `Get-AGTATestExitCode`; failure must be nonzero.

The script must write exactly one JSON object to stdout:

```json
{
  "ok": true,
  "testCase": "Microsoft Paint.csv",
  "runRoot": "C:\\...",
  "startedAt": "2026-06-21T12:00:00.0000000+02:00",
  "finishedAt": "2026-06-21T12:01:00.0000000+02:00",
  "steps": [],
  "summary": {
    "total": 5,
    "passed": 5,
    "failed": 0,
    "skipped": 0
  },
  "artifacts": {
    "resultPath": "C:\\...\\results\\result.json",
    "evidenceRoot": "C:\\...\\evidence",
    "commandLogPath": "C:\\...\\logs\\potato-commands-20260622_101500.jsonl",
    "cleanup": []
  },
  "executionId": "20260622_101500",
  "cleanup": []
}
```

The same JSON must also be saved to `results\result.json`. Prefer `Complete-AGTAGeneratedTest` for this instead of hand-building the result envelope.

## Cleanup

Generated scripts must perform cleanup at the end of every run, even if the testcase does not explicitly include cleanup steps.

Cleanup must:

- close applications or windows opened by the script,
- delete fixed-path or external files created during the run that could affect the next execution,
- remove temporary state that would make a rerun take a different UI path,
- preserve evidence, screenshots, transcripts, and result JSON under `RunRoot`,
- record cleanup actions and cleanup errors in the final JSON.

Cleanup should run after step execution regardless of pass/fail outcome. If cleanup itself fails, record the error in the final JSON rather than hiding it.

Development/iteration should normally run the generated script once after each behavioral automation change. If a later edit only changes result formatting or reporting, prefer a static parse check and targeted validation instead of another full GUI rerun.

## Coordinate Fallbacks

Coordinate clicks and drags are allowed only when selector-based automation is not reliable. The script must include a short comment and save a screenshot near the fallback action.

## Runtime additions

The template accepts `-InteractionPolicy`, `-PolicyReason`, and `-Transport`. InProcess is the default; Process preserves the previous transport. Policy is fixed at initialization. Result `interactionPolicy` records mode, reason, and compliance. `timing` records totalMs, wrapperMs, backendMs, commandOverheadMs, waitMs, cleanupMs, and otherMs; wait/cleanup overlap command timing. `Complete-AGTAGeneratedTest -PassThru` returns the result object without emitting JSON and never exits its caller. Entry points must emit the result and then call `exit (Get-AGTATestExitCode)`.

Use `Read-AGTAArtifactBytes` / `Assert-ArtifactPrefix` for bounded shared reads after stable-file waits; content assertions still belong to the testcase. Direct static `File.ReadAllBytes` calls are rejected in generated-script preflight because they can conflict with the application's open file handle. Runtime `start` waits briefly for a closing prior instance, rejects one that remains, and automatically registers a newly owned process. Explicit `Register-OpenedProcess -StartResult` remains idempotent but is not needed after `Invoke-StepCommand start`; legacy process-name registration is rejected.

## Preflight and readback

`GeneratedScriptRuntime.ps1` dot-sources `ArtifactAssertions.ps1` and `GeneratedScriptPreflight.ps1`. Call `Get-AGTARuntimeHelp -Name <helper>` to inspect loaded helpers instead of searching a single source file. The template calls `Assert-AGTAGeneratedScriptPreflight` before initialization; it checks parsing, called command names/parameters, and supplied CLI/CSV paths without driving the desktop. The API authoring tools also apply this check when writing and running a generated script.

For shell authoring, `Get-RuntimeHelp.ps1 -Name <helper>` returns full JSON help. `Invoke-Exploration.ps1` records a full GUI walkthrough, including observation receipts for every CSV row. `Test-GeneratedScript.ps1 -ScriptPath <file> -TestCaseCsv <csv> -PotatoCliPath <cli> -ExplorationPath <manifest>` validates it before execution. Runtime initialization defaults ExplorationPath to RunRoot/logs/exploration.json, or accepts an explicit manifest from the walkthrough run. CSV hash, policy, coverage, and transcript hash must match. The runtime also audits its calling script so omitting standalone preflight cannot bless the observed direct COM/native-input/data-fabrication patterns. These are audit checks, not a sandbox or proof of semantic correctness. `Invoke-StepClick` defaults to Auto. `Assert-FileWait` accepts Message and infers the path from the wait result.

`type -Verify` polls until `-VerifyTimeoutMs` (default 3000 ms) or a supplied positive `-MaxAttempts` limit. It never retypes. `-VerifyMode Exact|Contains|NormalizedExact|NormalizedContains` controls comparison; normalized modes reconcile line endings. `-TimeoutMs` is the selector lookup deadline. On failure the CLI reports attempt count and observed length without embedding field contents.
