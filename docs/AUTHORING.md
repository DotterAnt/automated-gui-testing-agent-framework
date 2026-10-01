# Authoring entry point

Read this guide, the supplied CSV and templates/GeneratedScript.Template.ps1 together. Use targeted help for missing signatures. The full contract/source are references for concrete unresolved questions.

If `agta_explore`/`agta_help` MCP tools are available, prefer them: `agta_help` topic authoring with testCaseCsv returns this guide, template and supplied CSV together; `agta_explore` accepts Begin/Batch/RecordSteps/Status/Complete as structured arguments. Keep desktop requests sequential and use the same verification/cleanup workflow below. The persistent process avoids outer shell/client startup per request. After a failed batch, inspect Status/GUI before recovery. See `docs/MCP.md` for one-time setup. The shell examples below apply when MCP is unavailable.

## Finish the workflow

Perform every CSV row through the GUI, including save, close/reopen, print/export and content assertions. Record each fully verified row, then Complete after cleanup. Generate, execute and repair until the delivered revision passes all rows, assertions and cleanup. Preflight alone is not a passed test. Incomplete exploration means resume missing rows. Recover boundedly and continue; stop only on explicit instruction or a concrete external blocker. Never invent evidence or weaken expectations.

## Begin once

~~~powershell
& .\Invoke-Exploration.ps1 -Action Begin -RunRoot .\runs\walkthrough-unique -TestCaseCsv '<supplied.csv>'
~~~

Keep the returned absolute RunRoot and explorationEvidenceRoot. Begin saves CSV/CLI/policy configuration. Its evidence directory already exists; use it directly for exploration filenames unless the testcase requires a subfolder. Execution uses Context.ExecutionEvidenceRoot. Avoid a separate shell mkdir just to organize a few outputs. Keep full paths and add type -PathKind SaveFile/OpenFile for filename fields. Required extra subfolders must already exist. Infrastructure preparation does not create expected outputs; the GUI must create them.

## Batch known routes

Batch accepts 1..20 sequential commands, records every receipt and stops at the first failure/unmet wait. Group known actions with their postcondition; end at an observation when the next state is unknown. In a PowerShell shell tool, invoke the script directly with a literal JSON string in ONE call:

~~~powershell
$requests = @'
[
  {"stepIndex":1,"command":"start","arguments":["-ProcessName","app.exe","-Maximize"]},
  {"stepIndex":1,"command":"observe","arguments":["-Depth","3","-MaxElements","80"]}
]
'@
& .\Invoke-Exploration.ps1 -Action Batch -RunRoot '<returned-root>' -RequestsJson $requests
~~~

This uses the PowerShell process the tool already runs. It needs no OutputEncoding assignment, native pipe or nested powershell.exe; Auto still forwards to the reusable worker. The literal here-string prevents testcase expansion, and RequestsJson crosses no native argument boundary. Begin, RecordSteps, Status, Complete and help scripts should also be called directly. Do not create a separate file/wrapper per batch. Raw CLI calls do not record exploration receipts.

Use the older UTF-8 native pipe only when the caller is not PowerShell or its execution policy blocks direct script invocation: `$OutputEncoding = [Text.UTF8Encoding]::new($false)` then pipe the literal JSON to `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Batch -RunRoot '<root>' -RequestsStdin`. Never pass raw RequestsJson across powershell.exe -File; native quoting can corrupt it. RequestsPath supports existing files. Choose a shell tool's no-profile option when available; the framework cannot remove startup/profile time charged by the outer tool.

Default Auto transport reuses one hidden local PowerShell host per RunRoot across these ordinary shell calls; no interactive session handle is needed. The current-user-only pipe processes requests sequentially, retains receipts/policy, and stops each batch at failure. The host exits after successful Complete or five idle minutes. StopHost stops only the transport and leaves exploration resumable. Transport InProcess runs directly for diagnosis or hosts that cannot retain background children. After framework/CLI updates, StopHost before resuming. A lost response has outcome unknown: inspect the GUI/Status before retrying, since the host may have performed the action.

JSON strings use `\r\n` or `\n` for actual line breaks. PowerShell backticks inside a literal JSON here-string are literal text; do not write `` `r`n `` when a testcase requires a newline. Structured *Json option values are accepted in both exploration batches and generated replays; already serialized JSON strings stay unchanged.

With interactive process stdin, launch once:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ExplorationStream.ps1 -RunRoot '<returned-root>'
~~~

Keep its process/session handle. Send one JSON line through stdin, inspect responses, then send the next request:

~~~json
{"action":"Batch","requests":[{"stepIndex":1,"command":"observe","arguments":["-Depth","3","-MaxElements","80"]}]}
~~~

Other actions: RecordSteps (requests array), Status, Complete and Quit. The same CSV/policy/receipt validation applies, while loaded UIA/native helpers stay warm. Failure stops the stream and queued requests; inspect the failed outcome before restarting on the same RunRoot. Complete ends the stream. Quit leaves exploration resumable. Without interactive stdin, use one-shot Batch. Never queue dependent actions across an unknown state.

Compact output is default; full envelopes remain in logs/exploration-commands.jsonl. Each command returns its receipt and verification eligibility. Workflow appears on the final batch response/failure; follow missingSteps/nextAction. Full mode includes workflow on every response.

The final Auto response includes explorationTiming.clientMs (entrypoint to host reply) and hostMs (worker validation, CLI and receipt work). logs/exploration-transport.jsonl also records connection time, PID and whether a host was started. Compare these with the shell tool's duration to locate time outside the framework. Tool duration includes outer shell startup/transport; it is not UI action time. Use tests/Measure-ExplorationLatency.ps1 for read-only direct/native-client measurements.

Combine only needed help:

~~~powershell
& ..\potato-cli\potato.ps1 help -Topics click,type,observe
& .\Get-RuntimeHelp.ps1 -Names Invoke-StepCommand,Assert-TextContains,Read-AGTAZipText
~~~

## Record reviewed evidence

For RecordSteps use the same direct RequestsJson transport or stream:

~~~json
[{"stepIndex":1,"route":"Performed GUI route","observedResult":"Actual complete expected result","verificationCommandIds":["<real-observation-receipt>"]}]
~~~

Use actual IDs from that row; multiple receipts support compound expectations. Read verification.eligible and review whether the observations prove the entire expectation. Dispatch alone is insufficient. type -Verify proves current text, not saving/persistence. A title proves window state, not contents. Screenshot evidence needs visual inspection.

Status returns missing rows, failures and ownership receipts. Close exploration-owned windows through the GUI and verify exit before Complete. Complete seals the manifest and returns replayReferencePath (compact tested actions/guards/verification references) and routesPath (full discovery history). Read the small reference first. Successful recovery may still start from a wrong state: omit unnecessary second drags/mode switches and revalidate the corrected route. Do not add untested selector constraints during generation.

## Ownership and dialogs

Start defaults to RequireNewWindow: existing hosts are allowed; old windows are not claimed. Plain focus switches existing test windows without cleanup ownership. Closing a document may leave its application open; use Open through the GUI rather than relaunching. Never kill a shared host for a fresh PID.

Before a file-manager GUI Open/double-click that launches another app: windows -Checkpoint, perform the action, inspect the observed unique window, then focus -SinceCheckpoint <checkpointId> with that selector. Only a new window gets ownedWindow for scoped cleanup. Direct file/protocol/shell launches bypass the GUI route.

Owned dialogs prefer Scope FocusedWindow. Broker dialogs need their exact observed title/class guard and fallback evidence. After submit, windows -Foreground -WindowTitle '<tested dialog title>' -TimeoutMs 15000 waits for that foreground title and returns count 0 on timeout. Assert count before using foregroundSelector. Bare windows -Foreground is a snapshot, not a transition check. Do not filter by the main app's PID; a broker may use another process.

A complete replay guard pattern is:

~~~powershell
$dialog = Invoke-StepCommand -Commands $Commands -Command windows -Arguments @('-Foreground','-WindowTitle','<tested exact title>','-TimeoutMs','15000')
Assert-PotatoFound $dialog 'Expected foreground dialog'
$scope = @('-Scope','ForegroundWindow','-WindowSelectorJson',$dialog.data.foregroundSelector,
    '-FallbackReason','Observed dialog route','-FallbackEvidence',$Context.CommandLogPath)
# Add the observed control selector, full Text path, PathKind, PreDelete and Verify.
$typed = Invoke-StepCommand -Commands $Commands -Command type -Arguments ($scope + @('-AutomationId','<observed id>','-Text',$path,'-PathKind','SaveFile','-PreDelete','-Verify'))
Assert-PotatoOk $typed 'Filename must be entered and verified'
~~~

Runtime *Json values accept JSON strings, hashtables, ordered dictionaries or path arrays; objects are serialized before invocation. Capture a fresh foregroundSelector per replay, rather than embedding a previous PID. Scoped input waits for the exact guard for TimeoutMs (default 1000), checks again before input and never activates another window. Use a tested wait for slow transitions, not repeated submits or fixed sleeps.

## Discovery and typing

Observe defaults to Compact. Bound scope/depth/count; deepen only when needed. DepthBoundaryReached/SearchIncomplete are not absence or uniqueness evidence. Try an observed subtree or visible-label fragment (select -Name '*fragment*' -TimeoutMs 0) before coordinates. Alternative observed names fit one SelectorJson Name array. Avoid repeated timed guesses and whole-tree dumps used as delays. Window-title waits inspect native top-level/owned windows instead of every desktop descendant.

When only the current editor/filename field or focus is needed, start with scoped `observe -Depth 0 -MaxElements 1`: focusedElement and keyboardFocus still report the actual focused target without walking the whole dialog tree. Use its observed selector as a candidate; input still checks writability, uniqueness and live focus. Inspect a bounded tree only when additional controls/layout are needed. Avoid expanding file lists/ribbon trees to hundreds of nodes just to identify the focused field. Real startup, provider calls, literal typing and required stable-file waits can exceed one second; reduce avoidable host/discovery work rather than shortening correctness deadlines.

Use minimal observed selectors and click Auto. Resolve AmbiguousTarget from candidates; do not choose the first duplicate or freeze opaque Pane roles. Native submit buttons use mouse activation to avoid synchronous UIA invocation errors. After ambiguous dispatch inspect the actual postcondition before retrying. Screenshots, UIA and clicks use physical pixels; inspect images and account for region origin.

GuiNavigation permits visible routes and audited bounded Tab/ShiftTab/Enter/Escape/arrows/focused input. Preserve explicit VisibleControls, which forbids navigation. Application hotkeys/Shortcut clearing, clipboard, object models, direct output creation and private input backends require explicit authorization. Selector failure is not authorization.

Selector type checks writability/focus; a separate click is usually redundant. For an opaque canvas, visibly enter editing state then type -TargetMode Focused with reason/evidence and an observed ExpectedFocusJson when available. Native keyboardFocus corroborates false UIA flags. After one failure inspect error.focus and make one targeted correction. If typing creates a new keyboard target, enter editing state first and preserve the tested route.

Default pacing is 5 ms per Unicode scalar; legacy TypeByCharacter uses 50 ms. Preserve tested pacing. PreDelete uses supported UIA/native selection plus Backspace, also in Focused mode; opaque canvases need visible selection. Verify polls without committing/resending. Commit through a visible control/permitted Enter before saved-value assertions. On mismatch inspect/reset before one slower retry; preserve full paths. Enter/Escape are single actions followed by observation.

## Generate and replay

Use Invoke-AGTATestPlan with one body per CSV row and InProcess transport. It handles dependency skips, assertions, cleanup and final output. Runtime preflights each execution; avoid duplicate preflight calls after repairs. Avoid read-only automatic variables such as HOME/PID. After behavior changes replay the corrected revision with its completed manifest and fresh paths. Inspect summary.failedSteps/cleanupOk first; successful cleanup needs no duplicate close/process probes. Repair an argument/serialization error with a small read-only reproduction first; do not repeatedly replay the whole GUI flow while guessing guard fields or weakening its scope.

Assert-PotatoOk proves command execution. Use Assert-PotatoFound for existence, Assert-ExpectedResult for state and wait-file -MinBytes 1 -StableMs 500 with Assert-FileWait for files. Reopen through the GUI, read actual content and Assert-TextContains for every fragment. Titles/signatures do not replace content/persistence assertions. Image-only PDFs need actual image/content checks, including cropping.

Read-AGTAArtifactBytes reads exactly Count bytes (1..1048576), with shared access and bounded lock retries. For ZIP content use Read-AGTAZipText -Path <artifact> -EntryPattern '<tested text/XML entries>'; it reads actual matching entries without guessing file size. It is read-only; expected outputs still come from the GUI. read-pdf handles transient locks internally. Malformed/unsupported content needs diagnosis, not repeated parse/sleep loops.

Compact replay stdout contains row status, failed commands and evidence/log paths. Full results stay in results/result.json. -OutputMode Full on Invoke-AGTATestPlan/Complete-AGTAGeneratedTest restores verbose stdout; -PassThru returns the full object. Read only needed failure details. JSON/exit status must agree. Cleanup only owned windows/processes; preserve evidence and report unresolved failures honestly. Broad process-name termination is not recovery authorization.
