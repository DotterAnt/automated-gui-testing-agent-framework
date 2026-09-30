# Authoring entry point

Read this page, the supplied CSV, and `templates/GeneratedScript.Template.ps1`. Skip unrelated testcase CSVs and application examples. Use CLI `help -Topic <command>` for a specific command. Do not read whole implementation modules or application examples without an unresolved defect.

## Interaction policy

The default is **GuiNavigation**, in exploration, execution, and cleanup. Use visible menus, buttons, text fields, and bounded `press-key` navigation. `Tab`, `ShiftTab`, `Enter`, `Escape`, and arrow keys are allowed with `-FallbackReason` and `-FallbackEvidence` describing the observed GUI state. Enter/Escape are single actions; observe their result before continuing. An explicit **VisibleControls** requirement stays strict and forbids `press-key`. Required menu/button routes must still be performed even when a navigation key could reach the same result. Application hotkeys, Ctrl+A clearing, clipboard, object models, file-association opening, and direct creation of expected outputs remain prohibited by default.

`type` normally requires a writable UIA control. If the visibly focused editor has no writable pattern, use `type -TargetMode Focused -Text <literal> -FallbackReason <reason> -FallbackEvidence <reference>`. This sends literal text to existing application focus, with no selector or implicit refocus. It refuses explicit read-only controls, embedded navigation characters, PreDelete, and unrelated foreground windows. It reports the actual target and never claims content verification unless requested. Both typing modes accept fields in a proven owned modal window; matching a process name alone is insufficient. Never replace the CLI with a private SendKeys/SendInput helper.

Only an explicit user/testcase allowance may select `AllowShortcuts`. Set `-InteractionPolicy AllowShortcuts -PolicyReason '<authorization>'` at runtime initialization/authoring launch. Every shortcut command then requires `-FallbackReason '<observed limitation>' -FallbackEvidence '<screenshot or observation reference>'`. Neither convenience nor a failed selector authorizes changing policy. Clipboard remains unsupported. Never use a per-command policy override in a generated script.

Pass the same policy to exploration and execution. Historical VisibleControls timings are not directly comparable with GuiNavigation timings. Compare runs with identical policies, CSV requirements, application state, and assertions.

## Minimal workflow

1. Map each row to its GUI route, expected assertion, dependencies, and unknowns. Create input/generated/evidence/logs/results folders.
2. Perform the **entire testcase once through the GUI before generating the script**, including required save/reopen/print/export routes, assertions, and cleanup. Discover only unknown controls during this walkthrough; reuse known selectors. Query bounded candidates by label before guessing ControlType. Keep exploration outputs separate from execution outputs. Record each row with the exploration entrypoint below. Failed or missing routes remain incomplete; never guess the remainder into a script or fabricate expected data.
3. Complete the exploration checkpoint, then generate from the template. Run `./Get-RuntimeHelp.ps1 -Name <helper>` for full signatures. Run `./Test-GeneratedScript.ps1 -ScriptPath <file> -TestCaseCsv <csv> -PotatoCliPath <cli> -ExplorationPath <manifest>` before execution. Pass the same manifest to generated scripts when executing in a fresh RunRoot. The checkpoint checks CSV hash, policy, all rows, successful observation receipts, and transcript hash. Runtime initialization independently checks exploration and audits the calling script for GUI bypasses.
4. Execute once, fix concrete failures, then rerun after behavior changes. Do not rerun only to polish reporting. Static checks are not a sandbox: honest observations and code review remain necessary. A request to continue until passing never authorizes fabricated outputs or weakened assertions.

### Recording exploration

From a PowerShell host, call the entrypoint directly so array arguments retain their boundaries. Use one run folder for the walkthrough:

```powershell
$e = @{RunRoot=$explorationRoot; TestCaseCsv=$csv; PotatoCliPath=$cli; InteractionPolicy='GuiNavigation'}
& ./Invoke-Exploration.ps1 @e -Action Begin
& ./Invoke-Exploration.ps1 @e -Action Command -StepIndex 1 -Command start -Arguments @('-ProcessName',$appExe)
# Perform the remaining row actions through -Action Command, then observe:
$receipt = & ./Invoke-Exploration.ps1 @e -Action Command -StepIndex 1 -Command read -Arguments @('-Name',$observedControl) | ConvertFrom-Json
& ./Invoke-Exploration.ps1 @e -Action RecordStep -StepIndex 1 -Route 'Actual route performed' -ObservedResult 'Actual expected result observed' -VerificationCommandId $receipt.explorationCommandId
# Repeat for EVERY CSV row, clean up the exploration-owned application, then:
& ./Invoke-Exploration.ps1 @e -Action Complete
```

In API authoring, `run_potato` takes `stepIndex` during exploration and returns `explorationCommandId`. Use `record_exploration_step` before transitioning to development. An observation command succeeding is insufficient if its returned state does not prove the CSV expectation. Screenshots require visual inspection, with the conclusion recorded in ObservedResult.

To avoid repeated shell startup and tool round trips, use `-Action Batch -RequestsPath <json-file>` for a short sequence whose selectors/transitions are already known. The file is an array of up to 20 objects with `stepIndex`, `command`, and string-array `arguments`. Commands run sequentially in one process, each emits its own receipt, and the batch stops on the first command failure or unmet wait. Never batch guessed transitions or continue after an unknown outcome. Prefer this receipt-producing batch to raw CLI pipelines during exploration.

After an action, wait for a specific UI/file postcondition instead of a fixed sleep. Desktop calls remain sequential. The CLI serializes overlapping commands with a bounded desktop mutex; this is not permission to run concurrent workflows. `outcome:unknown` means inspect the postcondition before retrying. Provider calls can outlast selector timeouts; no automatic retry of submissions or typing.

For interactive shell exploration, use `potato-stream.ps1` when the shell supports clean, non-echoing persistent pipes: one JSON request per line, read its response before sending the next. A one-shot pipeline can also run several already-known sequential commands in one process. An echoing terminal may wrap or decorate JSON, so use `potato.ps1` there. Generated scripts already use the in-process transport.

The exploration entrypoint records the required receipts; raw CLI/stream calls alone do not satisfy that checkpoint. The stream stops on failure by default, preventing queued actions from running against an unexpected state. `-ContinueOnError` is for interactive callers that read and reconcile each response.

`start` confirms a process and possibly a window, not a ready landing screen. Inspect the visible controls or wait for the next expected control, then choose the route for the observed state. `wait-element -ControlType Window` includes the working window itself; assert `data.exists`. Do not infer one application's initial state from a previous launch.

## Runtime helpers

```powershell
$Context = Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot
$results += Invoke-RecordedStep -StepIndex 1 -Body {
    param([ref] $Commands, [ref] $Evidence)
    # Invoke-StepCommand; Assert-PotatoOk checks dispatch, not the expected result.
    # Assert-ExpectedResult compares actual UI state/content with the CSV expectation.
}
$cleanup = @(Invoke-TestCleanup) # place in finally
Complete-AGTAGeneratedTest -StepResults $results -Cleanup $cleanup
exit (Get-AGTATestExitCode)
```

- `Invoke-StepCommand -Commands $Commands -Command <name> -Arguments @(...)` records compact summaries and full execution-specific transcripts. `type` with an explicit selector uses `-FocusMethod Auto`: it checks writability, tries UIA focus, then visibly clicks the field only if focus is unconfirmed. It verifies focus before sending text, so a separate click is usually unnecessary. `type -Verify` polls readback for up to 3000 ms by default; use `-VerifyMode NormalizedExact|NormalizedContains` for multiline text. `-VerifyTimeoutMs` controls readback, while `-TimeoutMs` controls selector lookup. A failed readback does not resend input. The default InProcess transport avoids a new PowerShell process for every command; `-Transport Process` remains available for compatibility comparisons.
- `Invoke-StepClick -Commands $Commands -Arguments @(<selector>)` records the click and checks dispatch. It defaults to `-Method Auto`, which uses a supported UIA action or visible mouse click. Supply `-Method Invoke` only after confirming InvokePattern in `select`/`observe`; an unsupported explicit method fails with the available patterns. Assert the resulting application state separately.
- For an unnamed subregion of an observed element, `click <selector> -RelativeX 0.5 -RelativeY 0.4` uses fractions of its current bounds. Fractions must stay inside the element; no screen-resolution constants belong in shared helpers. `drag -SourceSelectorJson <selector> -TargetSelectorJson <selector> [-DurationMs 300]` presses, moves, and releases; optional Source/TargetRelativeX/Y choose subregions. The button releases even on movement failure. Assert the actual drop result separately.
- Commit pending edits before checking the committed value. Use `type` without immediate verification for controls whose value updates on commit, then an observed visible commit action or permitted `press-key -Key Enter`, followed by read/assert. A failed `type -Verify` never means it is safe to resend text.
- `read-pdf -Reader Auto -PythonPath <installed-python.exe>` tries the built-in reader and, if unsupported, the shipped read-only pypdf helper. The Python must have pypdf installed; no download occurs. `POTATO_PDF_PYTHON` can configure it once. Validate this reader against the exploration output before the full execution run. The result records the reader used. Never generate a replacement PDF to satisfy an assertion.
- Start in a clean session. Runtime `start` requires a new application process, waits briefly for a closing prior instance, and automatically registers its owned PID and start time for cleanup. Do not add a redundant manual registration or remove ownership tracking to work around a failure; inspect `ownedProcessId` if ownership is unclear. Cleanup never closes by broad process name. Create a fresh document through its visible route, even if some document is already present.
- Closing a document may leave the owned application running. Continue through that application's Open UI when the testcase requests closing/reopening a document; do not assume a new process launch is needed. An unrelated existing application/background process is a precondition issue, not permission to kill by name.
- Scope dialog input with `-PathJson`/`-SelectorJson` and `-ProcessId`. `-ModalOnly` restricts a selector to modal-window descendants. Confirm a text target is editable, and scope optional prompt dismissal to the owned process and dialog. `windows -ProcessId` reports `isModal`; modal windows may be nested beneath their owner in UIA, and cleanup closes them before the parent.
- `Assert-ExpectedResult -Condition <bool> -Message <expectation>` records a required assertion. `Assert-PotatoFound` checks existence; it does not prove document content. Assertions default on; catching a failed assertion cannot turn the step into PASS.
- For asynchronous outputs: use a unique execution path, `wait-file -MinBytes 1 -StableMs 500`, then `Assert-FileWait -Result $wait [-Message <expectation>]`; the assertion reads the path from the wait result, and `-Path` remains available. Use `Read-AGTAArtifactBytes -Path ... -Count ...` or `Assert-ArtifactPrefix -ExpectedBytes ...` for bounded reads with sharing/retries. Generated-script preflight rejects direct `[IO.File]::ReadAllBytes`, which may fail while an application holds the output open. A signature alone is not a content check. Reopen through the app and read the execution marker back when content persistence is required.
- Verify selected output destinations through UIA value/selection state, not merely a button Name or an exploration screenshot of the default setting.
- `Invoke-EvidenceScreenshot` records useful evidence; it is not itself an assertion. `Register-CreatedExternalPath` is for outputs created by this execution; never register pre-existing user files.
- Final success requires all CSV rows exactly once, passing assertions, policy compliance, and successful cleanup. Missing output fails; no WARN+PASS. JSON and process exit status must agree.

Result timing reports command wrapper/backend time, wait-command time, cleanup, and other elapsed time. Cleanup and wait timings overlap command totals; do not add them all together. Optimize repeated discovery and transport first; retain the required GUI routes and checks.
