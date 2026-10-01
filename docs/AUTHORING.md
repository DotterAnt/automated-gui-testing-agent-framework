# Authoring entry point

Read this guide, the supplied CSV and templates/GeneratedScript.Template.ps1 together. Use targeted help for missing signatures. The full contract/source are references for concrete unresolved questions.

## Finish the workflow

Perform every CSV row through the GUI, including save, close/reopen, print/export and content assertions. Record each fully verified row, then Complete after cleanup. Generate, execute and repair until the delivered revision passes all rows, assertions and cleanup. Preflight alone is not a passed test. Incomplete exploration means resume missing rows. Recover boundedly and continue; stop only on explicit instruction or a concrete external blocker. Never invent evidence or weaken expectations.

## Begin once

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Begin -RunRoot .\runs\walkthrough-unique -TestCaseCsv '<supplied.csv>'
~~~

Keep the returned absolute RunRoot and explorationEvidenceRoot. Begin saves CSV/CLI/policy configuration. Its evidence directory already exists; use it for exploration filenames. Execution uses Context.ExecutionEvidenceRoot. Keep full paths and add type -PathKind SaveFile/OpenFile for filename fields. Extra subfolders must already exist. Infrastructure preparation does not create expected outputs; the GUI must create them.

## Batch known routes

Batch accepts 1..20 sequential commands, records every receipt and stops at the first failure/unmet wait. Group known actions with their postcondition; end at an observation when the next state is unknown. In ONE shell tool call, pipe literal UTF-8 JSON:

~~~powershell
$OutputEncoding = New-Object Text.UTF8Encoding($false)
@'
[
  {"stepIndex":1,"command":"start","arguments":["-ProcessName","app.exe","-Maximize"]},
  {"stepIndex":1,"command":"observe","arguments":["-Depth","3","-MaxElements","80"]}
]
'@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Batch -RunRoot '<returned-root>' -RequestsStdin
~~~

Set OutputEncoding each invocation; the literal here-string prevents testcase expansion. Do not create a separate file/wrapper per batch or pass arrays across powershell.exe -File. RequestsPath supports existing files; RequestsJson is for in-process callers such as the stream, avoiding native shell JSON quote loss. Raw CLI calls do not record exploration receipts.

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

Combine only needed help:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ..\potato-cli\potato.ps1 help -Topics click,type,observe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Get-RuntimeHelp.ps1 -Names Invoke-StepCommand,Assert-TextContains,Read-AGTAZipText
~~~

## Record reviewed evidence

For RecordSteps use the same UTF-8 transport or stream:

~~~json
[{"stepIndex":1,"route":"Performed GUI route","observedResult":"Actual complete expected result","verificationCommandIds":["<real-observation-receipt>"]}]
~~~

Use actual IDs from that row; multiple receipts support compound expectations. Read verification.eligible and review whether the observations prove the entire expectation. Dispatch alone is insufficient. type -Verify proves current text, not saving/persistence. A title proves window state, not contents. Screenshot evidence needs visual inspection.

Status returns missing rows, failures and ownership receipts. Close exploration-owned windows through the GUI and verify exit before Complete. Complete seals the manifest and returns replayReferencePath (compact tested actions/guards/verification references) and routesPath (full discovery history). Read the small reference first. Successful recovery may still start from a wrong state: omit unnecessary second drags/mode switches and revalidate the corrected route. Do not add untested selector constraints during generation.

## Ownership and dialogs

Start defaults to RequireNewWindow: existing hosts are allowed; old windows are not claimed. Plain focus switches existing test windows without cleanup ownership. Closing a document may leave its application open; use Open through the GUI rather than relaunching. Never kill a shared host for a fresh PID.

Before a file-manager GUI Open/double-click that launches another app: windows -Checkpoint, perform the action, inspect the observed unique window, then focus -SinceCheckpoint <checkpointId> with that selector. Only a new window gets ownedWindow for scoped cleanup. Direct file/protocol/shell launches bypass the GUI route.

Owned dialogs prefer Scope FocusedWindow. Broker dialogs need their exact observed title/class guard and fallback evidence. After submit, windows -Foreground -WindowTitle '<tested dialog title>' -TimeoutMs 15000 waits for that foreground title and returns count 0 on timeout. Assert count before using foregroundSelector. Bare windows -Foreground is a snapshot, not a transition check. Do not filter by the main app's PID; a broker may use another process.

Runtime *Json values accept JSON strings, hashtables, ordered dictionaries or path arrays; objects are serialized before invocation. Capture a fresh foregroundSelector per replay, rather than embedding a previous PID. Scoped input waits for the exact guard for TimeoutMs (default 1000), checks again before input and never activates another window. Use a tested wait for slow transitions, not repeated submits or fixed sleeps.

## Discovery and typing

Observe defaults to Compact. Bound scope/depth/count; deepen only when needed. DepthBoundaryReached/SearchIncomplete are not absence or uniqueness evidence. Try an observed subtree or visible-label fragment (select -Name '*fragment*' -TimeoutMs 0) before coordinates. Alternative observed names fit one SelectorJson Name array. Avoid repeated timed guesses and whole-tree dumps used as delays. Window-title waits inspect native top-level/owned windows instead of every desktop descendant.

Use minimal observed selectors and click Auto. Resolve AmbiguousTarget from candidates; do not choose the first duplicate or freeze opaque Pane roles. Native submit buttons use mouse activation to avoid synchronous UIA invocation errors. After ambiguous dispatch inspect the actual postcondition before retrying. Screenshots, UIA and clicks use physical pixels; inspect images and account for region origin.

GuiNavigation permits visible routes and audited bounded Tab/ShiftTab/Enter/Escape/arrows/focused input. Preserve explicit VisibleControls, which forbids navigation. Application hotkeys/Shortcut clearing, clipboard, object models, direct output creation and private input backends require explicit authorization. Selector failure is not authorization.

Selector type checks writability/focus; a separate click is usually redundant. For an opaque canvas, visibly enter editing state then type -TargetMode Focused with reason/evidence and an observed ExpectedFocusJson when available. Native keyboardFocus corroborates false UIA flags. After one failure inspect error.focus and make one targeted correction. If typing creates a new keyboard target, enter editing state first and preserve the tested route.

Default pacing is 5 ms per Unicode scalar; legacy TypeByCharacter uses 50 ms. Preserve tested pacing. PreDelete uses supported UIA/native selection plus Backspace, also in Focused mode; opaque canvases need visible selection. Verify polls without committing/resending. Commit through a visible control/permitted Enter before saved-value assertions. On mismatch inspect/reset before one slower retry; preserve full paths. Enter/Escape are single actions followed by observation.

## Generate and replay

Use Invoke-AGTATestPlan with one body per CSV row and InProcess transport. It handles dependency skips, assertions, cleanup and final output. Runtime preflights each execution; avoid duplicate preflight calls after repairs. Avoid read-only automatic variables such as HOME/PID. After behavior changes replay the corrected revision with its completed manifest and fresh paths. Inspect summary.failedSteps/cleanupOk first; successful cleanup needs no duplicate close/process probes.

Assert-PotatoOk proves command execution. Use Assert-PotatoFound for existence, Assert-ExpectedResult for state and wait-file -MinBytes 1 -StableMs 500 with Assert-FileWait for files. Reopen through the GUI, read actual content and Assert-TextContains for every fragment. Titles/signatures do not replace content/persistence assertions. Image-only PDFs need actual image/content checks, including cropping.

Read-AGTAArtifactBytes reads exactly Count bytes (1..1048576), with shared access and bounded lock retries. For ZIP content use Read-AGTAZipText -Path <artifact> -EntryPattern '<tested text/XML entries>'; it reads actual matching entries without guessing file size. It is read-only; expected outputs still come from the GUI. read-pdf handles transient locks internally. Malformed/unsupported content needs diagnosis, not repeated parse/sleep loops.

Compact replay stdout contains row status, failed commands and evidence/log paths. Full results stay in results/result.json. -OutputMode Full on Invoke-AGTATestPlan/Complete-AGTAGeneratedTest restores verbose stdout; -PassThru returns the full object. Read only needed failure details. JSON/exit status must agree. Cleanup only owned windows/processes; preserve evidence and report unresolved failures honestly. Broad process-name termination is not recovery authorization.
