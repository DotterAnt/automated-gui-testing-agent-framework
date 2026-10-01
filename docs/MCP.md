# Persistent exploration tools

`Invoke-ExplorationMcp.ps1` is a local MCP stdio server using Windows PowerShell and the existing exploration entrypoint. It exposes two tools, `agta_explore` and `agta_help`. One process stays loaded; requests avoid both outer shell-tool startup and cold PowerShell clients. CSV/policy validation, argument normalization, actual receipts, batch failure boundaries, recording eligibility and completion checks still run in `Invoke-Exploration.ps1` with InProcess transport. No app-specific routes are built in. No additional package/runtime installation is needed.

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

## Authoring flow

Prefer these tools when available. Call `agta_help` with `{"topic":"authoring","testCaseCsv":"<absolute supplied CSV path>"}` to read the guide, template and CSV together. Then:

~~~json
{"action":"Begin","runRoot":"<unique absolute run folder>","testCaseCsv":"<absolute supplied CSV path>"}
~~~

Pass these arguments to `agta_explore`; keep its returned runRoot and explorationEvidenceRoot. Batch uses the same command objects as the shell/stream:

~~~json
{"action":"Batch","runRoot":"<returned root>","requests":[{"stepIndex":1,"command":"observe","arguments":["-Depth","0","-MaxElements","1"]}]}
~~~

Batch at most 20 known sequential commands and stop at an observation for unknown transitions. Keep desktop tool calls sequential. Real failure receipts are returned with MCP `isError`; the server remains alive for diagnosis. After a failed batch, further batches for that run are blocked until a successful `Status` request. Review the failed receipt and actual GUI before submitting a separate recovery request. This does not retry or resume queued commands automatically. If the client loses a response, inspect Status/GUI before retrying an action that may already have happened.

Use `RecordSteps` with requests containing stepIndex, route, observedResult and real verificationCommandIds. `Status` and `Complete` need only action/runRoot. Complete still requires all verified rows and cleanup of owned windows; it returns replay references. Finish generation and actual replay using the normal runtime contract. The MCP process can serve another unique run afterward; EOF/client shutdown ends it. Restart it after framework updates. Use one transport per active walkthrough and do not submit shell and MCP mutations concurrently.

Targeted signatures: `agta_help` with `{"topic":"cli","names":["type","observe"]}` or `{"topic":"runtime","names":["Invoke-StepCommand","Assert-TextContains"]}`. Do not read entire contracts/modules or unrelated testcase examples speculatively. The shell/direct and interactive stream transports remain available when MCP tools are unavailable.

## Timing and diagnosis

The last exploration response includes `mcpTiming.requestMs`, measuring server dispatch, CLI and receipt work. The client/tool round trip can add time outside it. Startup/import costs are paid once per server connection. Actual UI provider work, literal typing and required postcondition waits remain.

Run `tests/ExplorationMcp.Tests.ps1 -OutFile <path>` for protocol, policy, receipts/failure/recovery and a sequential read-only latency comparison with fresh-shell direct invocation. It uses isolated CLI state and real receipts. It excludes agent-side MCP transport and one-time initialization; a local benchmark is not a measured full VM workflow speedup.

For the remaining shell route, run `tests/Measure-ShellStartup.ps1 -OutFile <path>` directly inside the test VM. It compares profile/default-policy, no-profile/default-policy and no-profile/Bypass launches without changing configuration. Compare its process times with a trivial agent shell-tool call: a slow outer tool cannot be diagnosed from CLI duration alone. Where the shell tool exposes `login`, request `login=false` to avoid profile loading. Do not add a nested shell just to obtain NoProfile. Codex's optional `allow_login_shell=false` setting is documented in [the configuration reference](https://developers.openai.com/codex/config-reference/); profile suppression is a startup experiment, not proof that a profile caused the logged delay.
