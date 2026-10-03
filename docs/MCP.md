# Persistent exploration tools

`Invoke-ExplorationMcp.ps1` is a local MCP stdio server using Windows PowerShell. It exposes `agta_explore`, `agta_inspect`, `agta_help` and read-only `agta_validate`. Version 1.8.1 includes stable-prefix typing and a conservative document-input default, following removal of diagnostic/incremental replay and Live workflow mode. Explore with recorded batches, then generate and run the complete saved script through the shell. Noninteractive protocol execution, piped receipt assertions and bounded retained CLI workers remain. Reconnect after updating to refresh the tool list. CSV/policy, receipt and assertion checks apply; no app-specific routes or extra packages are needed.

The server exposes GuiNavigation and VisibleControls by default. It rejects AllowShortcuts even with a nonempty policyReason and blocks mutations of older permissive runs; Status remains available for diagnosis. A model-written explanation is not user authorization. Application actions such as Open/Print must use visible menu/button routes. The operator may add `-EnableShortcutPolicy` to server startup only for an explicitly authorized shortcut task; tools cannot enable that capability, and per-run PolicyReason is still required. Do not add this flag for ordinary GUI tests. These are authoring checks, not an execution sandbox for arbitrary shell code.

## Register on the test machine

Configure a local stdio MCP server through the agent's integrations settings, using command `powershell.exe` and arguments `-NoProfile`, `-NonInteractive`, `-ExecutionPolicy`, `Bypass`, `-File`, and the absolute path to `Invoke-ExplorationMcp.ps1`. Each argument is a separate array item. Alternatively, merge this table into the existing `%USERPROFILE%\.codex\config.toml` (preserve other settings):

~~~toml
[mcp_servers.agta]
command = 'powershell.exe'
args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\diplomamunka\automated-gui-testing-agent-framework\Invoke-ExplorationMcp.ps1']
startup_timeout_sec = 60
tool_timeout_sec = 180
~~~

Codex documents stdio servers and the shared desktop/CLI/IDE configuration in [its MCP guide](https://developers.openai.com/codex/mcp/). The configuration belongs on the interactive test machine, where the CLI/framework and applications are installed. Adjust the script path if needed. Start a new agent chat/reconnect the integration after configuration or code updates; verify that `agta_explore` and `agta_help` are available. The server is launched by the MCP client; do not manually start it in a terminal or wrap each request in a shell command. No HTTP listener is involved. The launch's Bypass affects that process only, so it does not require changing machine-wide execution policy.

## Explore, then run the saved script

Read `agta_help` topic authoring with the CSV once. Begin/Batch explores real controls before any script is needed; review RecordSteps, clean owned windows and Complete. Generate the replay from those receipts and run the entire saved script through the shell, using the supplied CSV/CLI and completed runRoot. It preflights internally and performs normal cleanup. On failure inspect bounded history with `agta_inspect`, fix the script and rerun it in full. One successful full run completes validation without repetition. See [AUTHORING.md](AUTHORING.md) for the invocation.

The MCP server provides exploration and read-only inspection; it no longer hosts saved-script sessions, per-row execution, repair or skip operations. Older completed exploration manifests remain usable for full saved-script replay. There is no Live mode or script-hash qualification gate. Assertions follow the supplied CSV: PDF existence-only expectations use wait-file and Assert-FileWait, without rendering or content extraction.

Prefer these tools when available. Call `agta_help` with `{"topic":"authoring","testCaseCsv":"<absolute supplied CSV path>"}` to read the guide, template and CSV together once; do not duplicate those reads through shell calls. Guide/template are plain strings without PowerShell provider metadata. Then:

~~~json
{"action":"Begin","runRoot":"<unique absolute run folder>","testCaseCsv":"<absolute supplied CSV path>"}
~~~

Pass these arguments to `agta_explore`; keep its returned runRoot and explorationEvidenceRoot. Batch uses the same command objects as the shell/stream:

~~~json
{"action":"Batch","runRoot":"<returned root>","requests":[{"stepIndex":1,"command":"observe","arguments":["-Depth","0","-MaxElements","1"]}]}
~~~

For a known handoff, bind an earlier result directly instead of inventing a placeholder or waiting for another model round trip:

~~~json
{"action":"Batch","runRoot":"<root>","requests":[
 {"stepIndex":1,"command":"windows","key":"baseline","arguments":["-Checkpoint"]},
 {"stepIndex":1,"command":"click","arguments":["-Name","<observed opening control>"]},
 {"stepIndex":1,"command":"focus","arguments":["-WindowTitle","<observed destination>","-SinceCheckpoint",{"resultRef":"baseline","path":"data.checkpointId"},"-TimeoutMs","15000"]}
]}
~~~

Result references select `data.property` paths from earlier successful requests with unique `key` labels in the same batch. Supported value options: SinceCheckpoint, WindowSelectorJson, WindowIdentityJson, ProcessId, NativeWindowHandle, WaitForChangeFrom, WaitForImageMatch. They cannot bind option names, input text, policy or expressions. The entire batch's literal arguments/reference structure is checked before dispatch. A missing runtime property stops remaining commands; inspect the source receipt/Status. The transcript records actual resolved arguments; resolve fresh identities/paths again in saved PowerShell replay. Ordinary strings remain literal.

Batch at most 20 known sequential commands and stop at an observation for unknown transitions. Keep desktop tool calls sequential. Real failure receipts are returned with MCP `isError`; the server remains alive for diagnosis. After a failed batch, further batches for that run are blocked until a successful `Status` request. Review the failed receipt and actual GUI before submitting a separate recovery request. This does not retry or resume queued commands automatically. If the client loses a response, inspect Status/GUI before retrying an action that may already have happened.

Use `RecordSteps` with requests containing stepIndex, route, observedResult and real verificationCommandIds. `Status` and `Complete` need only action/runRoot. Complete still requires all verified rows and cleanup of owned windows; it returns replay references. Finish generation and actual replay using the normal runtime contract. The MCP process can serve another unique run afterward; EOF/client shutdown ends it. Restart it after framework updates. Use one transport per active walkthrough and do not submit shell and MCP mutations concurrently.

Every verification ID must follow that row's successful GUI action; recording order itself is unrestricted. Correct an early/wrong receipt using existing later observations instead of repeating completed GUI work. Whole batches are checked for run-policy violations before the first command, including forbidden hotkeys, Shortcut clearing and per-command policy overrides.

For closure, use a Batch windows command with the exact owned WindowIdentityJson/tested selector, WaitForNotExists and a bounded TimeoutMs; assert data.conditionMet. Confirmed disappearance is eligible evidence. Plain windows with a positive TimeoutMs waits for appearance, so count 0 after a close wastes the deadline and is ineligible. Every ID in RecordSteps must be eligible.

Targeted signatures: `agta_help` with `{"topic":"cli","names":["type","observe"]}` or `{"topic":"runtime","names":["Invoke-StepCommand","Assert-TextContains"]}`. Do not read entire contracts/modules or unrelated testcase examples speculatively. The shell/direct and interactive stream transports remain available when MCP tools are unavailable.

Complete returns the compact tested replay reference inline, with its saved path for later use. Do not load the verbose exploration-routes.json discovery export. After compaction, `agta_help` with `{"topic":"replay","runRoot":"<root>","stepIndex":1}` restores only the requested row's tested arguments. Generate and run the full saved script through the shell; it validates internally. `agta_validate` is optional read-only preflight for an unresolved source question, not a required extra call before execution.

## Timing and diagnosis

`agta_inspect` with `source:"image"`, absolute `imagePath`/`referencePath`, optional observed `region` and clockwise `referenceRotation` measures retained decoded display pixels, including EXIF orientation. It returns error metrics/dimensions without input, file writes, tolerance changes or a qualifying PASS. Use it to diagnose stale captures, wrong regions/orientation or persisted image content before another GUI attempt. Command-history inspection remains the default.

Screenshot commands return PNG/JPEG pixels inline with their receipt and physical region, eliminating a separate image-view call. Up to the last two screenshots of a Batch are attached, each bounded to 10 MiB; the saved files remain authoritative. Batch includeImages false disables attachments. Inspect returned pixels directly; do not call view_image again for the same image. Unsupported formats/oversized images retain their valid receipt/path with an inline warning. Compact windows preserve actionable identity/guards/bounds while full property details stay in the command transcript.

Compact observe presents one `elementColumns` header and `elementRows` arrays. Bounds are `[x,y,width,height]` in physical pixels. Flags contain focused/disabled/offscreen/ambiguous only when applicable; every node, pattern and selector is preserved. The original objects remain in the transcript. Target small observations before broadening depth/node budgets. Original screenshots remain unchanged.

The last exploration response includes `mcpTiming.requestMs`, measuring server dispatch, CLI and receipt work. The client/tool round trip can add time outside it. Startup/import costs are paid once per server connection. Actual UI provider work, literal typing and required postcondition waits remain.

Protocol execution is noninteractive: missing mandatory arguments fail immediately instead of prompting on JSON-RPC stdin. Existing configurations without -NonInteractive automatically enter a hidden noninteractive host with raw byte forwarding; no request becomes a PowerShell prompt answer. Adding the flag above avoids that compatibility process and its one-time startup. The host/provider exit with their parent. Assert-PotatoOk, Assert-PotatoFound, Assert-FileWait and Assert-TextContains accept each receipt through the pipeline as well as explicit Result arguments; they stop on the first failure and retain normal assertions/provenance/freshness checks.

MCP and the Auto shell host retain a separate hidden CLI worker so a synchronous UIA/provider call cannot hold the server forever. Its default command deadline is 30 seconds, extended for explicit CLI waits and intentional paced typing plus 5 seconds, up to 70 seconds. Text length, requested pacing and final verification contribute to the typing budget; short calls retain the ordinary deadline. Timeout stops only that worker, preserves application windows and returns ProviderTimeout with outcome unknown. No action is retried: inspect Status/actual GUI before further input. A fresh worker handles subsequent commands. `logs/active-provider-command.json` records the command before dispatch and its deadline/state; agta_inspect includes this progress alongside bounded command history. The worker exits with its parent. Direct InProcess/Process shell transports do not use this isolation by default. The deadline bounds CLI calls, not arbitrary script/helper loops. Full saved-script execution runs independently through the shell.

Run `tests/ExplorationMcp.Tests.ps1 -OutFile <path>` for protocol, policy, receipts/failure/recovery and a sequential read-only latency comparison with fresh-shell direct invocation. It uses isolated CLI state and real receipts. It excludes agent-side MCP transport and one-time initialization; a local benchmark is not a measured full VM workflow speedup.

For the remaining shell route, run `tests/Measure-ShellStartup.ps1 -OutFile <path>` directly inside the test VM. It compares profile/default-policy, no-profile/default-policy and no-profile/Bypass launches without changing configuration. Compare its process times with a trivial agent shell-tool call: a slow outer tool cannot be diagnosed from CLI duration alone. Where the shell tool exposes `login`, request `login=false` to avoid profile loading. Do not add a nested shell just to obtain NoProfile. Codex's optional `allow_login_shell=false` setting is documented in [the configuration reference](https://developers.openai.com/codex/config-reference/); profile suppression is a startup experiment, not proof that a profile caused the logged delay.
