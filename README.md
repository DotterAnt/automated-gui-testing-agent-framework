# Automated GUI Testing Agent Framework

For the fastest exploration path, register the local `Invoke-ExplorationMcp.ps1` stdio server once, then use its `agta_explore` and `agta_help` tools. It keeps the framework/CLI in one process and avoids a fresh shell/client per tool request while retaining validation and receipts. [MCP setup and usage](docs/MCP.md). Direct shell calls below remain the fallback.

For CSV authoring, read `AGENTS.md`, `docs/AUTHORING.md`, the supplied CSV and the generated template together. In PowerShell shell tools, call `& .\Invoke-Exploration.ps1` directly with `-RequestsJson` for batches, rather than spawning another powershell.exe and piping encoded text. Auto retains the worker; direct invocation also avoids a cold client. Use `RecordSteps` for reviewed receipts and `Status` for progress. `Complete` exports tested command routes for reuse. The template's `Invoke-AGTATestPlan` handles sequencing, dependent skips, cleanup and result output. The contract and source modules are references for specific unresolved questions.

PowerShell-only framework for turning CSV testcase descriptions into repeatable GUI automation scripts that use `potato-cli`.

`Invoke-Exploration.ps1` defaults to Auto transport: a hidden local host stays warm across ordinary shell calls, using a current-user-only pipe and the existing CSV/policy/receipt checks. It exits after successful Complete or five idle minutes; StopHost leaves the walkthrough resumable. Transport InProcess runs directly for diagnosis. Interactive agents can instead keep `Invoke-ExplorationStream.ps1` open. Complete returns `replayReferencePath` for a small route reference. Replay stdout defaults to row status and actionable failures; full results and command transcripts stay on disk, with `-OutputMode Full` available on the test plan/completion helper. Generic `Read-AGTAZipText` verifies text/XML entries in an output archive without guessing its byte count. See the authoring guide for transport and dialog-wait examples.

The final Auto response reports client/worker request timing, and `logs/exploration-transport.jsonl` records connection/startup/PID details. Run `tests/Measure-ExplorationLatency.ps1` for a read-only comparison of direct invocation and a native-pipe client. Outer shell-tool startup/transport is outside these measurements.

[Watch the PoTATo demo recording](https://github.com/DottedAnt-Dooz/automated-gui-testing-agent-framework/releases/download/demo-v1/demo.mkv)

## Workflows

### 1. Agent Session Workflow

Use this when a coding agent such as Codex, Copilot, or Hermes is running in an interactive Windows desktop session.

1. Point the agent at this folder.
2. Provide a testcase CSV, for example `Microsoft Paint.csv`.
3. Ask the agent to generate and validate a PowerShell GUI test script.
4. The agent should follow `AGENTS.md`, `docs\AUTHORING.md`, and the generated script template. Consult the full contract for unresolved schema questions.
5. The agent must work in three stages: Planning, Exploration, and Development/Iteration.

### 2. API Workflow

Use this when a model is called through an API and the framework owns tool execution.

Graphical launcher:

```powershell
cd C:\diplomamunka\automated-gui-testing-agent-framework
.\Invoke-AgentAuthoringGui.ps1
```

The GUI lets a user load a CSV, preview and edit testcase rows, edit the system prompt and optional user prompt override, choose the API vendor, set the model/API key, and launch authoring.

Command-line launcher:

```powershell
cd C:\diplomamunka\automated-gui-testing-agent-framework
.\Invoke-AgentAuthoring.ps1 -TestCaseCsv ".\Microsoft Paint.csv" -Provider OpenAI -Model "gpt-5.5" -Execute
```

For a no-network dry run:

```powershell
.\Invoke-AgentAuthoring.ps1 -TestCaseCsv ".\Microsoft Paint.csv" -Provider Mock
```

The OpenAI provider reads `OPENAI_API_KEY` from the environment and uses the Responses API with function tools. The tool loop is allowlisted: the model can read the testcase, run PoTATo commands, write a generated script, run that script when `-Execute` is set, read run artifacts, and finalize.

The API workflow exposes a `set_authoring_stage` tool. The model must enter `planning`, then `exploration`, then `development_iteration`. PoTATo exploration commands are blocked until the exploration stage is active, and generated-script writing/running is blocked until development/iteration is active.

Both workflows default to GuiNavigation: visible GUI routes with audited, bounded navigation keys and focused literal input. An explicitly requested VisibleControls policy remains strict. Application hotkeys and Shortcut clearing require authorized AllowShortcuts; recovery never authorizes a GUI bypass. A completed, evidence-backed exploration of every CSV row is required before generation and execution. See `Invoke-Exploration.ps1` and `docs/AUTHORING.md`.

Generated scripts must also clean up after themselves before exiting. They should preserve run-folder evidence, but close any applications they opened and delete fixed-path or external files/state they created that could make a later run fail or take a different path.

The Development/Iteration stage includes optimization after the script is functionally correct. Agents should make scripts faster and more robust by using explicit waits, stronger selectors, fewer redundant exploratory commands, intentional evidence capture, and deterministic dialog handling.

Generated scripts should keep final JSON small. Full PoTATo responses belong in execution-specific command logs under `logs\`; the final result should contain compact command summaries and a `commandLogPath`. This keeps Codex/API contexts and dashboards from being dominated by large UI trees.

Generated scripts should dot-source `Framework\GeneratedScriptRuntime.ps1` instead of copying the shared helper layer. The runtime provides PoTATo invocation, command logging, step result creation, evidence registration, cleanup, and final JSON writing. Agents should keep generated scripts focused on testcase-specific GUI actions and assertions.

Start authoring from `templates\GeneratedScript.Template.ps1` and CLI `help -Topic <command>`. New scripts enable `-RequireAssertions`: command success or screenshots alone cannot pass a functional step. Required interaction routes and user/testcase prohibitions take precedence over fallback preferences. Preserve failed attempts, use unique execution outputs, and run all desktop actions sequentially. See the generated-script contract for result and verification semantics.

Run focused regression checks with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Runtime.Regression.Tests.ps1`. They validate reporting/assertion behavior using fixtures without driving an application. A live application regression is still needed before adopting behavior changes in an evaluation VM.

OpenAI API references:

- [Responses API](https://developers.openai.com/api/reference/responses/overview/)
- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [Agents SDK](https://developers.openai.com/api/docs/guides/agents)

## Folder Layout

- `Framework\AutomatedGuiTestingAgentFramework.psm1` - runtime module.
- `Framework\GeneratedScriptRuntime.ps1` - shared helper runtime for generated scripts.
- `Invoke-AgentAuthoring.ps1` - API/mock orchestration entrypoint.
- `Invoke-AgentAuthoringGui.ps1` - WinForms launcher for API-driven authoring.
- `docs\GENERATED_SCRIPT_CONTRACT.md` - required generated script format.
- `prompts\SESSION_AGENT_PROMPT.md` - prompt for robust coding agents.
- `docs\AUTHORING.md` - concise policy, discovery, runtime, and verification guide.
- `runs\` - generated runtime artifacts, ignored by git.

## Required CSV Columns

```csv
Action,Data,Expected Result
Open Paint,,Paint opened
```

Optional columns are accepted and preserved when present:

- `StepId`
- `Application`
- `Notes`

## Common Commands

Create a run folder:

```powershell
Import-Module .\Framework\AutomatedGuiTestingAgentFramework.psm1 -Force
New-AGTARunDirectory -TestCaseCsv ".\Microsoft Paint.csv"
```

Invoke PoTATo safely:

```powershell
Invoke-AGTAPotatoJson -PotatoCliPath "..\potato-cli\potato.ps1" -Command "state" -RunRoot ".\runs\manual"
```

Build the analysis dashboard:

```powershell
cd ..\automated-gui-testing-agent-analysis
.\Invoke-BuildAnalysisDashboard.ps1 -RunsRoot "..\automated-gui-testing-agent-framework\runs" -Open
```

See `..\automated-gui-testing-agent-analysis\README.md` for metric files, cost-estimate configuration, and dashboard details.

## Environment Assumptions

v1 assumes the VM is already logged into an interactive desktop. It does not restore checkpoints, call LoginAgent, unlock the desktop, or install applications.

## Policy and execution changes

Start with `docs/AUTHORING.md`. Complete the full GUI walkthrough and its exploration manifest, then generate from the shared template. InProcess execution reuses the CLI module while Process remains available for controlled comparisons. Generated scripts emit JSON and exit with `Get-AGTATestExitCode`. Runtime start registers the new process or individual new shared-host window for cleanup. Static checks reject observed COM/native-input/data-fabrication bypasses, but are not a sandbox. Mock reports incomplete exploration and cannot generate, execute, or claim GUI coverage.
