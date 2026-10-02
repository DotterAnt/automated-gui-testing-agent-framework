# Persistent exploration tools

`Invoke-ExplorationMcp.ps1` is a local MCP stdio server using Windows PowerShell. It exposes `agta_explore`, `agta_replay`, `agta_inspect`, `agta_help` and read-only `agta_validate`. One process retains state/ownership. Version 1.3.1 fixes setup path validation, preserves setup source locations and requires explicit CSV row attribution for input Repair. Live remains the default, with replay also available through agta_explore and failed Verify sessions retained. Reconnect after updating. CSV/policy, receipt and assertion checks apply; no app-specific routes or extra packages are needed.

The server exposes GuiNavigation and VisibleControls by default. It rejects AllowShortcuts even with a nonempty policyReason and blocks mutations of older permissive runs; Status remains available for diagnosis. A model-written explanation is not user authorization. Application actions such as Open/Print must use visible menu/button routes. The operator may add `-EnableShortcutPolicy` to server startup only for an explicitly authorized shortcut task; tools cannot enable that capability, and per-run PolicyReason is still required. Do not add this flag for ordinary GUI tests. These are authoring checks, not an execution sandbox for arbitrary shell code.

## Register on the test machine

Configure a local stdio MCP server through the agent's integrations settings, using command `powershell.exe` and arguments `-NoProfile`, `-ExecutionPolicy`, `Bypass`, `-File`, and the absolute path to `Invoke-ExplorationMcp.ps1`. Each argument is a separate array item. Alternatively, merge this table into the existing `%USERPROFILE%\.codex\config.toml` (preserve other settings):

~~~toml
[mcp_servers.agta]
command = 'powershell.exe'
args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\diplomamunka\automated-gui-testing-agent-framework\Invoke-ExplorationMcp.ps1']
startup_timeout_sec = 60
tool_timeout_sec = 180
~~~

Codex documents stdio servers and the shared desktop/CLI/IDE configuration in [its MCP guide](https://developers.openai.com/codex/mcp/). The configuration belongs on the interactive test machine, where the CLI/framework and applications are installed. Adjust the script path if needed. Start a new agent chat/reconnect the integration after configuration or code updates; verify that `agta_explore` and `agta_help` are available. The server is launched by the MCP client; do not manually start it in a terminal or wrap each request in a shell command. No HTTP listener is involved. The launch's Bypass affects that process only, so it does not require changing machine-wide execution policy.

## Live authoring

Read `agta_help` topic authoring with the CSV once. Begin exploration, write the actual template StepBodies incrementally, and use agta_replay Start/Step. Failure keeps the live state: Status, Repair, retry the failed body or explicitly Skip for diagnostic continuation. Record reviewed receipts with agta_explore RecordSteps. Close qualifies an uninterrupted unchanged first-attempt session without replaying it twice. Repaired sessions need a final clean Verify. Use agta_inspect instead of raw log dumps. See [AUTHORING.md](AUTHORING.md) and, only for session details, [LIVE_REPLAY.md](LIVE_REPLAY.md).

Replay is also available through the established exploration tool:

~~~json
{"action":"Replay","replayAction":"Start","runRoot":"<existing absolute run folder>","scriptPath":"<absolute saved template path>"}
~~~

Use replayAction Step/Status/Repair/Skip/Close/Verify on that same runRoot. Input Repair must include `stepIndex` for the actual CSV row; Repair does not advance the plan. Retry Step, or Skip a manually completed pending row with a reason. Tool arguments are literal values, so pass an observed JSON selector object rather than a PowerShell variable name. Default Live mode allows only read-only Batch discovery. Unqualified script revisions are blocked from standalone full replay before GUI dispatch. Once the final revision qualifies, that exact delivered script can run standalone. Failed Verify retains the live session and blocks another full Verify until review/recovery/Close. Existing manifests without workflowMode retain compatibility behavior.

## Legacy recorded batches

The following separate-walkthrough flow requires explicit workflowMode RecordedBatch on Begin. Without MCP, the shell entrypoint retains this fallback. A missing agta_replay name alone does not require it; agta_explore Replay reaches the same session.

Prefer these tools when available. Call `agta_help` with `{"topic":"authoring","testCaseCsv":"<absolute supplied CSV path>"}` to read the guide, template and CSV together once; do not duplicate those reads through shell calls. Guide/template are plain strings without PowerShell provider metadata. Then:

~~~json
{"action":"Begin","workflowMode":"RecordedBatch","runRoot":"<unique absolute run folder>","testCaseCsv":"<absolute supplied CSV path>"}
~~~

Pass these arguments to `agta_explore`; keep its returned runRoot and explorationEvidenceRoot. Batch uses the same command objects as the shell/stream:

~~~json
{"action":"Batch","runRoot":"<returned root>","requests":[{"stepIndex":1,"command":"observe","arguments":["-Depth","0","-MaxElements","1"]}]}
~~~

Batch at most 20 known sequential commands and stop at an observation for unknown transitions. Keep desktop tool calls sequential. Real failure receipts are returned with MCP `isError`; the server remains alive for diagnosis. After a failed batch, further batches for that run are blocked until a successful `Status` request. Review the failed receipt and actual GUI before submitting a separate recovery request. This does not retry or resume queued commands automatically. If the client loses a response, inspect Status/GUI before retrying an action that may already have happened.

Use `RecordSteps` with requests containing stepIndex, route, observedResult and real verificationCommandIds. `Status` and `Complete` need only action/runRoot. Complete still requires all verified rows and cleanup of owned windows; it returns replay references. Finish generation and actual replay using the normal runtime contract. The MCP process can serve another unique run afterward; EOF/client shutdown ends it. Restart it after framework updates. Use one transport per active walkthrough and do not submit shell and MCP mutations concurrently.

Every verification ID must follow that row's successful GUI action; recording order itself is unrestricted. Correct an early/wrong receipt using existing later observations instead of repeating completed GUI work. Whole batches are checked for run-policy violations before the first command, including forbidden hotkeys, Shortcut clearing and per-command policy overrides.

For closure, use a Batch windows command with the exact owned WindowIdentityJson/tested selector, WaitForNotExists and a bounded TimeoutMs; assert data.conditionMet. Confirmed disappearance is eligible evidence. Plain windows with a positive TimeoutMs waits for appearance, so count 0 after a close wastes the deadline and is ineligible. Every ID in RecordSteps must be eligible.

Targeted signatures: `agta_help` with `{"topic":"cli","names":["type","observe"]}` or `{"topic":"runtime","names":["Invoke-StepCommand","Assert-TextContains"]}`. Do not read entire contracts/modules or unrelated testcase examples speculatively. The shell/direct and interactive stream transports remain available when MCP tools are unavailable.

After Complete and generation, call `agta_validate` with `{"runRoot":"<existing absolute exploration root>","scriptPath":"<absolute replay.ps1>"}`. This uses the saved CSV/CLI/policy/manifest and parses the replay without executing it. It rejects incomplete exploration and policy/signature/assertion issues, returns the checked script hash, and always reports replayExecuted/taskComplete false. A parser-only check cannot replace full preflight or the actual replay. Execute the checked revision and inspect its assertions and cleanup result.

## Timing and diagnosis

Screenshot commands return PNG/JPEG pixels inline with their receipt and physical region, eliminating a separate image-view call. Up to the last two screenshots of a Batch are attached, each bounded to 10 MiB; the saved files remain authoritative. Batch includeImages false disables attachments. Inspect returned pixels directly; do not call view_image again for the same image. Unsupported formats/oversized images retain their valid receipt/path with an inline warning. Compact windows preserve actionable identity/guards/bounds while full property details stay in the command transcript.

The last exploration response includes `mcpTiming.requestMs`, measuring server dispatch, CLI and receipt work. The client/tool round trip can add time outside it. Startup/import costs are paid once per server connection. Actual UI provider work, literal typing and required postcondition waits remain.

Run `tests/ExplorationMcp.Tests.ps1 -OutFile <path>` for protocol, policy, receipts/failure/recovery and a sequential read-only latency comparison with fresh-shell direct invocation. It uses isolated CLI state and real receipts. It excludes agent-side MCP transport and one-time initialization; a local benchmark is not a measured full VM workflow speedup.

For the remaining shell route, run `tests/Measure-ShellStartup.ps1 -OutFile <path>` directly inside the test VM. It compares profile/default-policy, no-profile/default-policy and no-profile/Bypass launches without changing configuration. Compare its process times with a trivial agent shell-tool call: a slow outer tool cannot be diagnosed from CLI duration alone. Where the shell tool exposes `login`, request `login=false` to avoid profile loading. Do not add a nested shell just to obtain NoProfile. Codex's optional `allow_login_shell=false` setting is documented in [the configuration reference](https://developers.openai.com/codex/config-reference/); profile suppression is a startup experiment, not proof that a profile caused the logged delay.
