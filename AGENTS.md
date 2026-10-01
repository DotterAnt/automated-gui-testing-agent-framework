# Agent instructions

Read `docs/AUTHORING.md`, the supplied CSV and `templates/GeneratedScript.Template.ps1` together first. Use targeted CLI/runtime help for missing signatures; do not load whole modules, the full contract, old examples or unrelated testcases speculatively.

Unless the user requests a narrower scope, finish every row's GUI exploration and actual verification, record its receipts, Complete, generate, then execute and repair until the delivered revision passes all rows, assertions and cleanup. Syntax/preflight or a saved script is not completion. Incomplete exploration means resume missing rows. Answer intervening status questions briefly and continue. Stop only on explicit instruction or a concrete external blocker after bounded recovery; identify unfinished rows and the needed intervention. Never fabricate evidence or weaken expectations.

Use documented UTF-8 JSON batches in one shell tool call each. Begin once and reuse its RunRoot. Default Auto transport keeps a local host warm across ordinary shell calls; interactive stdin can instead use Invoke-ExplorationStream.ps1. Keep desktop actions sequential, batch known routes and end at an observation when the next state is unknown. Batches/streams stop at the first failure. Inspect unknown outcomes before retrying. Read workflow on the final batch response/failure; record each fully verified row promptly. JSON newlines use \r\n, not PowerShell backticks inside a literal here-string.

GuiNavigation is default throughout; preserve explicit VisibleControls. Navigation and focused typing require observed reason/evidence and confirmed focus. Application hotkeys, Shortcut clearing, clipboard, object models, direct file/protocol launches, synthetic outputs and private input backends require explicit authorization. Selector failure never authorizes a bypass.

Start defaults to RequireNewWindow: never claim an old window or kill a shared host for isolation. Plain focus switches existing test windows without ownership. Before GUI opening into another app, use windows -Checkpoint, then focus its observed unique window with SinceCheckpoint for window-only cleanup. Close only registered processes/windows and verify actual exit.

Reuse tested minimal selectors, click Auto, pacing and transition guards. Resolve AmbiguousTarget from candidates. Avoid repeated guessed-label waits, observations used as delays, untested selector constraints and unconditional recovery actions. Depth boundaries/SearchIncomplete require scoped discovery, not absence claims. Inspect screenshots before coordinates; use physical pixels and region origin.

Owned dialogs prefer FocusedWindow. Broker dialogs use windows -Foreground with the tested title and TimeoutMs; assert count, then pass its exact foregroundSelector as WindowSelectorJson with fallback evidence. Never assume readiness or the main app's PID. Runtime *Json options accept objects as well as strings. Scoped input must not steal another window's focus.

Use selector typing for writable controls; focused typing for a visibly entered opaque editor. Inspect keyboardFocus/error.focus after one failure and make one targeted correction. Default pacing is 5 ms per Unicode scalar. If typing creates a new keyboard target, enter editing state first. ExpectedFocusJson waits without refocusing. PreDelete requires supported selection. Verify proves current readback; commit/save/reopen assertions are separate.

Use Begin's existing absolute explorationEvidenceRoot and Context.ExecutionEvidenceRoot, full literal paths and PathKind SaveFile/OpenFile. The GUI creates expected files. Verify every content/persistence expectation; signatures/titles do not prove contents, and image-only PDFs need image/content verification. Read-AGTAZipText inspects generic ZIP text; Read-AGTAArtifactBytes reads an exact Count.

Generate with Invoke-AGTATestPlan and InProcess transport. Read Complete's replayReferencePath first; routesPath retains full discovery history. Keep assertions and tested readiness checks. Runtime preflights every replay; rerun after behavior fixes without duplicate preflight. Check summary.failedSteps and cleanupOk first. Compact stdout links full result/command evidence. Successful cleanup needs no duplicate recovery.

Use commentary for meaningful findings/failures, without narrating every successful click or row recording. For argument errors, reproduce the conversion with read-only code before another full GUI replay; do not remove guard fields or change scope to hide serialization failures.
