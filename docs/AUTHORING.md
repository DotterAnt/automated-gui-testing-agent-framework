# Authoring entry point

Read this page, the testcase CSV, and templates/GeneratedScript.Template.ps1 together. They are sufficient to begin. Do not read whole runtime/preflight modules, unrelated CSVs, or application examples speculatively. Consult Get-RuntimeHelp.ps1 for a specific missing helper signature.

## Start with the supported transport

Use the following from a shell, including hosts where script execution is disabled. JSON files preserve arrays, quotes, spaces and Unicode across powershell.exe -File. Do not pass -Arguments @(...) across that process boundary or invent a temporary PowerShell wrapper for every call.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Begin -RunRoot .\runs\walkthrough-unique -TestCaseCsv '<supplied.csv>'
~~~

Keep that exact RunRoot. Begin stores the CSV path, CLI path and policy and returns the testcase rows. Map each row's GUI route, assertion, dependencies and unknowns. Create a short JSON request file:

~~~json
[
  {"stepIndex":1,"command":"start","arguments":["-ProcessName","app.exe","-Maximize"]},
  {"stepIndex":1,"command":"observe","arguments":["-Depth","3","-MaxElements","80"]}
]
~~~

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Batch -RunRoot .\runs\walkthrough-unique -RequestsPath .\requests.json
~~~

Batch accepts 1..20 sequential commands, records each receipt, and stops on the first failure or unmet wait. Use it even for a single command. Group already known actions and their postcondition in one call; end at an observation when the next transition is unknown. Never batch guessed dependent actions. Default output is compact, with full command envelopes in logs/exploration-commands.jsonl; -OutputMode Full restores verbose output. Use the supported entrypoint during exploration: raw CLI calls/streams do not record the required receipts.

Read only help that is needed. Multiple topics share one response/startup:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ..\potato-cli\potato.ps1 help -Topics start,observe,click,type,press-key
~~~

Do not make ten separate help calls. docs/GENERATED_SCRIPT_CONTRACT.md is a reference for unresolved schema questions.

## Complete the walkthrough

Perform the ENTIRE testcase once through the GUI before writing the final script: save, close/reopen, print/export, required content assertions, and cleanup. Discover only unknown controls within that full walkthrough. Keep exploration and execution outputs separate. Every row needs a successful observation receipt that actually proves its expectation, not just successful action dispatch.

After reviewing the results, write a JSON array of records with stepIndex, route, observedResult and verificationCommandId. The id comes from an actual command response. Record the routes already performed and the actual content/state observed; do not write planned observations.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action RecordSteps -RunRoot .\runs\walkthrough-unique -RequestsPath .\reviewed-rows.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Status -RunRoot .\runs\walkthrough-unique
~~~

Status returns missing rows, receipts, recent failures and owned process IDs. RecordStep remains available for individual rows. Close the exploration-owned application through the GUI and verify cleanup before Complete:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Complete -RunRoot .\runs\walkthrough-unique
~~~

Complete returns the immutable exploration manifest and logs/exploration-routes.json, a compact reference of tested commands grouped by row. Reuse successful action arguments when generating; remove discovery probes and add real assertions. Do not add guessed ControlType, ClassName or ModalOnly constraints during generation. Validate any new constraint or repaired route through the GUI.

API authoring uses run_potato with stepIndex and record_exploration_step, then transitions to development_iteration. The same full exploration gate applies. Missing routes must be reported honestly; never invent receipts, output artifacts or PASS assertions.

## Discover once, act on what was observed

- Use click's default Auto. It chooses supported UIA patterns or a visible mouse click. Explicit Invoke is only for a confirmed InvokePattern. A failed explicit method is not evidence that the desired action happened.
- observe is compact through the exploration entrypoint. For a native dialog use observe -Scope FocusedWindow -Depth 4 -MaxElements 80. This inspects the actual foreground window only after proving it belongs to the working application. select, read, click and type also accept -Scope FocusedWindow. It avoids searching a disabled parent, and does not depend on UIA IsModal.
- Compact observations give name/id, actual role/patterns, focus, bounds and candidate selectors. Confirm uniqueness in the same scope. Name plus AutomationId often suffices; a generic Pane with no patterns can be an incomplete provider view, so do not freeze that role into a selector. Use a screenshot and audited focused typing/navigation if the visible editor is opaque.
- Search alternative observed labels in one query: select -SelectorJson '{"Name":["Save","Browse"]}' -TimeoutMs 0 -MaxResults 10. This is discovery; count=0 is a valid result. Avoid polling several guessed labels for seconds each. Use wait-element with a timeout only for a genuinely expected transition.
- After start, check ownedProcessId/windowFound and wait for the actual next control. A splash window is not application readiness. Reuse recorded selectors for repeated routes. Use a unique execution output path and a postcondition after any submit; never retry typing/submission just because the result is ambiguous.
- Bound tree size and scope it to the relevant area. Full observe is available with -Format Full; increase depth only when the current observation misses the needed control. A screenshot requires visual inspection, not merely a saved filename.

## Policy and input

GuiNavigation is the default throughout exploration, execution and cleanup. Preserve an explicit VisibleControls requirement, which forbids press-key. Application hotkeys, Ctrl+A clearing, clipboard, object models, file-association opening and directly created expected output are prohibited by default. A selector failure never permits a non-GUI bypass or private SendKeys/SendInput backend.

press-key accepts Tab, ShiftTab, Enter, Escape and arrow keys with FallbackReason/FallbackEvidence describing the observed state. Enter/Escape are single actions followed by observation; required menu/button routes still apply. type -TargetMode Focused accepts literal text at existing confirmed application focus, with the same evidence requirement. It does not implicitly refocus or clear, rejects explicit read-only controls and embedded navigation characters, and needs a separate result assertion.

Normal type with a selector checks writability and focus, so a separate click is usually unnecessary. PreDelete uses UIA text selection and Backspace. type -Verify polls current readback without committing or resending. For commit-on-exit editors, type once, commit through a visible action/permitted Enter, then read/assert. NormalizedExact/NormalizedContains reconcile line endings. Relative element clicks and selector drag/drop use live bounds; verify the actual resulting state.

Only explicit user/testcase authorization permits AllowShortcuts with PolicyReason. Do not override policy per command. Clipboard remains unsupported. Keep desktop actions sequential. outcome:unknown requires observing before retry. Provider calls can exceed the selector retry timeout.

## Generate and validate

Use the template's Invoke-AGTATestPlan with one scriptblock per CSV row. It runs sequentially, marks dependent rows SKIPPED after failure, always cleans up and emits the final result. Keep application-specific actions/assertions in those bodies. This avoids hand-writing repeated skip/finally/result code. Existing Invoke-RecordedStep scripts remain supported.

Use InProcess transport. Run Test-GeneratedScript.ps1 once before the first execution; generated scripts already preflight themselves on every run. After a behavior fix, execute the corrected script with its manifest and a fresh RunRoot; a separate repeated preflight call is unnecessary. Rerun after behavior changes, not cosmetic reporting edits. Inspect the failed row and command transcript before changing a selector.

Assertions must prove the CSV expectation. Assert-PotatoOk proves dispatch only; screenshots are evidence, not assertions. Use Assert-PotatoFound for element existence, Assert-ExpectedResult for content/state, wait-file -MinBytes 1 -StableMs 500 with Assert-FileWait for files. Signatures alone do not verify contents. Reopen through the GUI when persistence is required. read-pdf supports the built-in reader and optional installed Python/pypdf via PythonPath or POTATO_PDF_PYTHON; check the reader during exploration.

start automatically registers a newly owned PID/start time for cleanup. Closing a document may leave the application running; use its Open UI rather than launching again. Close only owned windows. Cleanup failures preserve context for recovery; never compensate with broad process-name termination. Preserve evidence and report failures. All CSV rows, assertions, cleanup and policy checks must pass; JSON and exit status must agree. Static checks are an audit aid, not a sandbox.
