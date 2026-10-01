# Session agent prompt

Create a repeatable PowerShell GUI test from the supplied CSV. Read AGENTS.md, docs/AUTHORING.md, the CSV and templates/GeneratedScript.Template.ps1 together. Complete every row's GUI exploration and actual verification, record receipts, Complete, generate, execute and repair until the delivered revision passes all rows, assertions and cleanup. Do not stop at script creation or preflight.

Use documented sequential JSON batches, preferably persistent exploration when interactive stdin is available. Batch known routes and end at an observation for unknown transitions. Reuse RunRoot, tested selectors, pacing and guards. Read targeted help and compact results instead of whole modules/transcripts. GuiNavigation is default; preserve explicit stricter policy and ownership restrictions.

Wait for a tested foreground dialog before capturing its exact guard. Use that guard for scoped input with observed fallback evidence. Do not guess readiness, PID, focus or selector constraints. Commit edits and verify persisted content after GUI reopening. Expected outputs come from the GUI. Use shared generic artifact helpers, InProcess transport and Invoke-AGTATestPlan. After failure, inspect summary.failedSteps/cleanupOk, repair and rerun; successful cleanup and runtime preflight need no duplicate calls.
