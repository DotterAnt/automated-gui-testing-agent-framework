# Authoring entry point

Read this page, the testcase CSV, and templates/GeneratedScript.Template.ps1 together. They are sufficient to begin. Do not read whole runtime/preflight modules, unrelated CSVs, or application examples speculatively. Consult Get-RuntimeHelp.ps1 for a specific missing helper signature.

## Completion requirement

Unless the user explicitly asks for a narrower scope, finish the whole task in the current session: explore every CSV row through the GUI, record all verified rows and Complete the walkthrough, generate the script, then execute and repair it until the current script passes every row, its required assertions, and cleanup. Continue between stages without asking the user to prompt you again. Creating the first output file, writing the script, passing syntax/preflight, or completing only exploration does not finish the task. Replay after the last behavior change; an earlier run does not validate the delivered revision.

An `Exploration is incomplete` error is an instruction to continue the walkthrough. Use Status to find missing rows, perform any untested actions, record the real observations, and Complete before generating or executing. Do not describe the script as finished or "blocked only by exploration" while those actions are still available. A recoverable command failure calls for targeted observation and bounded recovery, not final delivery. Stop early only on an explicit user request or a concrete blocker that remains after permitted recovery and needs unavailable access, information, or capability. Report the unfinished rows, observed failure, attempted recovery, and exact intervention needed; keep the result incomplete without fabricating evidence or relaxing assertions.

A failed selector or unrecorded row is not itself an external blocker. If the user asks about progress or an error during the task, answer briefly and resume the authorized work unless they explicitly ask to stop or only want an explanation. Do not end with "I can continue" or defer executable remaining work to a "next iteration".

## Start with the supported transport

Use the following from a shell, including hosts where script execution is disabled. Pipe UTF-8 JSON directly to the batch entrypoint; this preserves arrays, quotes, spaces and Unicode across powershell.exe -File. Do not pass -Arguments @(...) across that process boundary or invent a temporary PowerShell wrapper for every call.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Begin -RunRoot .\runs\walkthrough-unique -TestCaseCsv '<supplied.csv>'
~~~

Keep that exact RunRoot. Begin stores the CSV path, CLI path and policy and returns the testcase rows. Map each row's GUI route, assertion, dependencies and unknowns. Send the request and execute it in ONE shell tool call:

Begin also creates and returns the absolute `explorationEvidenceRoot` (`<RunRoot>\evidence\exploration`). Build exploration filenames inside that existing directory; preserve the full returned path. This prepares an empty infrastructure folder only; all expected files still come from the application's GUI. Generated execution has its own existing `Context.ExecutionEvidenceRoot`. Arbitrary extra subfolders are not automatically created. If a testcase specifically requires creating a folder through the GUI, perform that route for the testcase folder. Status returns the exploration directory and whether it still exists.

~~~powershell
$OutputEncoding = New-Object Text.UTF8Encoding($false)
@'
[
  {"stepIndex":1,"command":"start","arguments":["-ProcessName","app.exe","-Maximize"]},
  {"stepIndex":1,"command":"observe","arguments":["-Depth","3","-MaxElements","80"]}
]
'@ | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Batch -RunRoot .\runs\walkthrough-unique -RequestsStdin
~~~

Use the literal here-string above so the shell cannot expand testcase text. Set OutputEncoding in each shell invocation. Existing JSON files are still supported with -RequestsPath, but do not make a separate file-edit tool call for every batch. The transcript already retains every request and response.

Batch accepts 1..20 sequential commands, records each receipt, and stops on the first failure or unmet wait. Use it even for a single command. Group already known actions and their postcondition in one call; end at an observation when the next transition is unknown. Never batch guessed dependent actions. Default output is compact, with full command envelopes in logs/exploration-commands.jsonl; -OutputMode Full restores verbose output. Use the supported entrypoint during exploration: raw CLI calls/streams do not record the required receipts.

Read only help that is needed. Multiple topics share one response/startup:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ..\potato-cli\potato.ps1 help -Topics start,observe,click,type,press-key
~~~

Do not make ten separate help calls. docs/GENERATED_SCRIPT_CONTRACT.md is a reference for unresolved schema questions.

For runtime helpers use one Get-RuntimeHelp.ps1 -Names Invoke-StepCommand,Assert-TextContains,Assert-FileWait call. CLI help preserves valid topics even if another is unknown; read those returned topics and the availableTopics list instead of searching the whole source for a guessed alias.

## File managers and cross-app routes

Explorer and other shared hosts are supported GUI surfaces. Framework `start` uses `RequireNewWindow`; an existing shell process is normal. Launch the file manager, inspect it, use its visible address bar/folder controls, enter a validated directory path, then select and Open/double-click the file. A visible Open with choice is allowed. Direct file/protocol launches through shell wrappers are not a GUI route. Do not close or kill the shell to obtain a fresh PID.

For a file-manager action that opens a viewer, call `windows -Checkpoint` immediately before the action. After inspecting the resulting window, `focus -SinceCheckpoint <returned checkpointId>` with its unique observed selector registers window-only cleanup. Plain `focus` switches to an existing test window without claiming its host. Keep an ownedWindow receipt for `close-window -WindowIdentityJson <receipt JSON>` during exploration; Complete checks that window, not whether its shared host exited. Generated runtime registers returned ownership automatically. Use RequireNewProcess only when the testcase needs strict process isolation.

For brokered save/print dialogs, `windows -Foreground` returns the actual root and `foregroundSelector`. Use that exact guard with Scope ForegroundWindow, fallback evidence, and (for Focused typing) ExpectedFocusJson. Observation, selection clicks, typing and bounded navigation work there without changing the application context. A missing working window is not a reason to adopt a broker process.

## Complete the walkthrough

Perform the ENTIRE testcase once through the GUI before writing the final script: save, close/reopen, print/export, required content assertions, and cleanup. Discover only unknown controls within that full walkthrough. Keep exploration and execution outputs separate. Every row needs a successful observation receipt that actually proves its expectation, not just successful action dispatch.

As each row is fully verified, review its results and record it; do not postpone all recording until the end. Pass a JSON array of records with stepIndex, route, observedResult and verificationCommandId using the same UTF-8 stdin pattern with -Action RecordSteps. The id comes from an actual command response. Record the routes already performed and the actual content/state observed; do not write planned observations. Successful type -Verify readback is valid evidence of the typed text; typing without verification is not. Neither proves saving or persistence.

Exploration responses include `workflow` with the stage, recorded/required counts, missing rows and next action. This progress reads only the small manifest, without another desktop observation. `ok` means the individual command succeeded; even Complete finishes only exploration. Follow the next action through generation and a passing execution of the delivered script.

Command responses now include verification.eligible. Nonempty windows observations are accepted for title/window state. Use verificationCommandIds as an array when a row needs several observations, such as wait-file plus windows; every ID must belong to that row and pass verification checks. Eligibility does not establish that the observation proves the entire expectation. The API accepts a primary verificationCommandId plus optional additional verificationCommandIds.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action RecordSteps -RunRoot .\runs\walkthrough-unique -RequestsPath .\reviewed-rows.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Status -RunRoot .\runs\walkthrough-unique
~~~

Status returns missing rows, receipts, recent failures and owned process IDs and owned-window receipts. RecordStep remains available for individual rows. Close the exploration-owned application through the GUI and verify cleanup before Complete:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Exploration.ps1 -Action Complete -RunRoot .\runs\walkthrough-unique
~~~

Complete returns the immutable exploration manifest and logs/exploration-routes.json, a compact reference of tested commands grouped by row. Reuse successful action arguments when generating; remove discovery probes and add real assertions. Do not add guessed ControlType, ClassName or ModalOnly constraints during generation. Validate any new constraint or repaired route through the GUI.

API authoring uses run_potato with stepIndex and record_exploration_step, then transitions to development_iteration. The same full exploration gate applies. Missing routes must be reported honestly; never invent receipts, output artifacts or PASS assertions.

## Discover once, act on what was observed

The CLI loads standard Windows UI Automation providers, including native dropdowns and menus. Prefer `click -Method Auto` on an observed dropdown, inspect its named choices, then click the intended item and verify the selection. Do not guess how many arrow presses reach an option. Repeated navigation stops on a changed window (and arrows on a changed focus target); observe before continuing. A command dispatch is not proof that the selection or dialog transition finished. Changing system settings through CIM/WMI or configuration cmdlets to avoid a GUI interaction is a bypass, including changing the default printer before opening its dialog.

Framework observations default to Compact in shell exploration, API exploration and generated execution; explicit Format Full is preserved. Receipts record the effective format. Reuse tested arguments, including input pacing and focus guards. A newly launched process can restore prior documents: inspect the initial state and reach a verified blank document through the GUI before typing; restarting alone is not a reset.

- Use click's default Auto. It uses a selector-based mouse click for native push buttons to avoid synchronous UIA invocation failures in file dialogs, and supported patterns for other controls. For existing Save/submit steps using explicit Invoke, prefer Auto or Mouse. `RPC_E_CANTCALLOUT_ININPUTSYNCCALL` / `0x8001010D` is an activation error, not evidence of a bad filename: inspect/dismiss the error, verify whether an output exists, then retry once with Mouse if still needed. Keep the observed selector and full path. A command dispatch is not proof of a successful save; assert dialog/file postconditions.
- Click requires one visible enabled match by default. If it returns AmbiguousTarget, no input was sent: use error.candidates to add an observed role, ID, class or parent scope. A navigation item and a submit button can share a label, as can document-close and application-close controls. Do not disable uniqueness to avoid resolving the actual ambiguity.
- observe is compact through the exploration entrypoint. For a native dialog use observe -Scope FocusedWindow -Depth 4 -MaxElements 80. This inspects the actual foreground window only after proving it belongs to the working application. select, read, click and type also accept -Scope FocusedWindow. It avoids searching a disabled parent, and does not depend on UIA IsModal.
- Compact observations give name/id, class, actual role/patterns, focus, bounds and candidate selectors. Duplicate labels gain observed role/class constraints when these distinguish them in the returned tree; unresolved duplicates are marked ambiguous. The live click check remains authoritative because a bounded tree may omit other matches. Editable candidates prefer ID over mutable text names. A generic Pane with no patterns can be an incomplete provider view, so do not freeze that role into a selector. Use a screenshot and audited focused typing/navigation if the visible editor is opaque.
- Search alternative observed labels in one query: select -SelectorJson '{"Name":["Save","Browse"]}' -TimeoutMs 0 -MaxResults 10. This is discovery; count=0 is a valid result. Avoid polling several guessed labels for seconds each. Use wait-element with a timeout only for a genuinely expected transition.
- After start, check ownedProcessId/windowFound and wait for the actual next control. A splash window is not application readiness. Reuse recorded selectors for repeated routes. Use a unique execution output path and a postcondition after any submit; never retry typing/submission just because the result is ambiguous.
- Bound tree size and scope it to the relevant area. Full observe is available with -Format Full; increase depth only when the current observation misses the needed control. A screenshot requires visual inspection, not merely a saved filename.
- depthBoundaryReached means deeper descendants were not inspected. Before concluding that UIA lacks a visible control, inspect a deeper subtree rooted at an observed container or query a short visible label fragment with select -Name '*fragment*' -TimeoutMs 0. Exact accessible names may include extra words. Stop after a useful scoped probe; do not repeatedly dump whole trees.
- Screenshot, UIA and mouse coordinates use physical pixels in every transport. Read imageWidth/imageHeight and region origin, inspect the actual image, then choose the point. Do not batch a new screenshot with a guessed coordinate click before viewing it. Prefer element-relative clicks; physical pixels do not make hardcoded coordinates independent of layout.

## Policy and input

When observation shows a control but a filtered selector misses it, the CLI now retries a bounded traversal using the same child enumeration as observe. SearchIncomplete requires narrowing to an observed container. Use the returned selector, including a role that disambiguates a menu item from its text child; avoid trying guessed variants or redundant Recurse flags.

For an observed system-hosted dialog outside the owner chain, use `-Scope ForegroundWindow -WindowSelectorJson '{"Name":"<observed exact title>","ClassName":"<observed exact class>"}'` plus fallback reason/evidence. This permits scoped observation/read/selector clicks/type/press-key without adopting the broker process or making it a cleanup target. Ordinary FocusedWindow remains restricted to the application owner. Prefer the guarded scope to fixed coordinates. Wait for the selected state and visible enabled submit control (`wait-element -InteractiveOnly`) before clicking once; then wait for the next observed dialog. Scoped waits tolerate a temporary owner/foreground mismatch, so do not encode repeated blind submission clicks and fixed multi-second sleeps as a reliable route.

GuiNavigation is the default throughout exploration, execution and cleanup. Preserve an explicit VisibleControls requirement, which forbids press-key. Application hotkeys, Ctrl+A clearing, clipboard, object models, non-GUI shell/protocol opening and directly created expected output are prohibited by default. A selector failure never permits a non-GUI bypass or private SendKeys/SendInput backend.

press-key accepts Tab, ShiftTab, Enter, Escape and arrow keys with FallbackReason/FallbackEvidence describing the observed state. Enter/Escape are single actions followed by observation; required menu/button routes still apply. type -TargetMode Focused accepts literal text at existing confirmed application focus, with the same evidence requirement. It does not implicitly refocus or clear, rejects explicit read-only controls and embedded navigation characters, and needs a separate result assertion.

For a custom editor/canvas, visibly enter text-edit mode and use `type -TargetMode Focused` directly; a writable UIA selector is unnecessary. The CLI corroborates focus with Windows' actual keyboard target in the owned foreground window. A false `focusedElement.focused` flag alone does not mean focus is absent: compare `keyboardFocus.ready`. The command waits up to FocusTimeoutMs (default 2000), never clicks/refocuses, and returns `data.inputFocus`. After a transition, preserve an observed `ExpectedFocusJson` guard for the intended field or native editor. If blocked, inspect `error.focus` and make one targeted observation/correction; do not cycle through guessed focus IDs, reread implementation/policy source, or repeatedly dump deep trees. If the visible route truly cannot edit, discover another user-visible editor view and verify its result. All routes remain GUI operations.

Focused input confirms the keyboard destination, not a caret or text-edit mode. Avoid batching a new coordinate guess, an unread observation and typing across an unknown transition. Read supported text patterns or inspect the resulting screenshot before continuing, and verify persistence/content as required. A screenshot with no visual inspection is insufficient. Preserve the transition guard in generated execution rather than adding whole-tree observations as timing delays.

Normal type with a selector checks writability and focus, so a separate click is usually unnecessary. PreDelete uses UIA or standard Windows Edit text selection and keyboard Backspace, also in Focused mode. PathKind enables exact readback by default. Standard Windows Edit readback works even when UIA reports no patterns. type -Verify polls current readback without committing or resending. For commit-on-exit editors, type once, commit through a visible action/permitted Enter, then read/assert. NormalizedExact/NormalizedContains reconcile line endings. Relative element clicks and selector drag/drop use live bounds; verify the actual resulting state.

Literal input defaults to paced Unicode scalars (`InputDelayMs 5`), with a native focus check during sending. `InputDelayMs 0` explicitly opts into bursts; legacy TypeByCharacter uses 50 ms. Begin with the default, verify real text, and increase pacing only for an observed loss. Preserve tested pacing in generation. Do not resend on a mismatch without first inspecting and resetting the intended field through the GUI. A character count or line/column label cannot prove exact content: use Verify/read plus Assert-TextContains, which normalizes CR/LF. Status labels are supplementary evidence only.

Use click Auto for a discovered popup item. It now performs the supported action without refocusing the parent/item first, which can dismiss a menu. Explicit Focus/ElementFocus overrides are for an observed need. A TargetNotFound failure is not-dispatched; inspect the current scope and actual label before changing the route. Do not switch to coordinates solely because a guessed role/name failed.

For field replacement prefer writable type -PreDelete -Verify. If the observed field is opaque but already focused, use -TargetMode Focused -ExpectedFocusJson '{"AutomationId":"<observed-id>"}' -FocusTimeoutMs 2000 plus fallback evidence. This waits for the expected owned focus without clicking or selecting anything. It preserves a selected default filename. Do not insert a click merely to wait for readiness: that can remove the selection and append the new path. Multiline input needs the writable Document control; a nested Edit may represent only one line. Use read to inspect text, never empty typing.

For filename input add `-PathKind SaveFile` (existing parent), `OpenFile` (existing file), or `Directory` (existing folder). This checks the literal absolute `-Text` path before focus/clearing/typing and creates nothing. Use the same full path for typing and `wait-file`; do not copy shortened labels from dialogs, add quote characters inside Text, or double-escape beyond the JSON syntax. `PathValidationFailed` stops the batch before a dependent Save click. An absolute path alone does not ensure its parent exists. For a missing infrastructure folder use the prepared directory; creating a new empty run subfolder is allowed with `[IO.Directory]::CreateDirectory($absoluteDirectory)`, but creating expected files directly is forbidden. Input validation is separate from field readback and persistence verification.

Only explicit user/testcase authorization permits AllowShortcuts with PolicyReason. Do not override policy per command. Clipboard remains unsupported. Keep desktop actions sequential. outcome:unknown requires observing before retry. Provider calls can exceed the selector retry timeout.

## Generate and validate

Use the template's Invoke-AGTATestPlan with one scriptblock per CSV row. It runs sequentially, marks dependent rows SKIPPED after failure, always cleans up and emits the final result. Keep application-specific actions/assertions in those bodies. This avoids hand-writing repeated skip/finally/result code. Existing Invoke-RecordedStep scripts remain supported.

Use InProcess transport. Run Test-GeneratedScript.ps1 once before the first execution; generated scripts already preflight themselves on every run. After a behavior fix, execute the corrected script with its manifest and a fresh RunRoot; a separate repeated preflight call is unnecessary. Rerun after behavior changes, not cosmetic reporting edits. Inspect the failed row and command transcript before changing a selector.

Initialize-AGTAGeneratedTest resolves all context paths against the PowerShell current location. Build dialog output filenames from $Context.ExecutionEvidenceRoot; they are absolute even when RunRoot was relative. Reuse the tested transition guards. Scoped Window waits now include the foreground dialog itself, but adding redundant untested waits after a successful exploration route still adds risk. The final result puts summary.failedSteps and cleanupOk before the detailed transcript: if cleanupOk is true, proceed with the repair without repeating close commands and process/window checks. A repaired script already performs its own preflight on rerun.

Assertions must prove EVERY part of the CSV expectation. Assert-PotatoOk proves dispatch only; screenshots are evidence, not assertions. Use Assert-PotatoFound for element existence, Assert-ExpectedResult for state, and wait-file -MinBytes 1 -StableMs 500 with Assert-FileWait for files. Signatures alone do not verify contents. When persistence is required, reopen through the GUI, read the actual document control, then call Assert-TextContains -Result $readback -Expected @($title,$paragraph). This helper checks every fragment and rejects an accessible name masquerading as document content. A window/document title alone does not prove reopened content; a later export assertion does not replace a missing reopen assertion. read-pdf supports the same helper, the built-in reader and optional installed Python/pypdf via PythonPath or POTATO_PDF_PYTHON; check the reader during exploration.

start defaults to RequireNewWindow and registers a new PID/start time or just a new window in an existing host for cleanup. Closing a document may leave the application running; use its Open UI rather than launching again. Close only owned windows. Cleanup failures preserve context for recovery; never compensate with broad process-name termination. Preserve evidence and report failures. All CSV rows, assertions, cleanup and policy checks must pass; JSON and exit status must agree. Static checks are an audit aid, not a sandbox.

`close-window` queues a normal asynchronous close for native windows, allowing any save/confirmation dialog to appear without blocking the command. `data.closeRequested` (and legacy `closed`) is a request count; observe owned windows or let runtime cleanup verify actual exit. The ownership context remains available. Never infer successful cleanup from dispatch alone.

After a stable nonempty PDF appears, `read-pdf -TimeoutMs 5000` handles transient file locks internally. Avoid script-specific retry/sleep loops around every PDF parse; malformed/unsupported content needs diagnosis. A retained cooperating producer handle is readable through the built-in shared snapshot. Actual spooling of a zero-byte file is separate: wait with a bounded deadline, inspect one failure, and preserve printer diagnostics rather than inflating stability waits for all runs.

If cleanup fails, inspect the failed run's command transcript and preserved CLI state. Recover the specific owned window through the CLI and resolve any visible prompt, then verify closure before restarting. A failed script does not authorize Get-Process by application name followed by CloseMainWindow/Stop-Process, including commands issued outside the generated script.

A successful exploratory command may still be part of a recovery from the wrong state. Do not copy recovery actions such as a second drag or wrong-mode switch into an unconditional replay. Revalidate the corrected route. Image-only PDFs require visual/content evidence; read-pdf text extraction and file signatures do not prove image content or absence of cropping. Final delivery must state a failed or untested replay honestly; passing static preflight is not a passed test.
