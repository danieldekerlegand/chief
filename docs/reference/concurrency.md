# Host-wide concurrency

`-p N` limits tasklists within one `chief run`; it is not a machine-wide CPU
budget. Every run reads the existing `~/.chief/runs/` registry before launching
an agent turn. Live agent phases across all repositories count against
`CHIEF_MACHINE_BUDGET`, whose default is the detected physical-core count.

When the budget is full, the scheduler holds pending work and prints
`machine budget hold` until another run finishes. It does not kill work already
in flight. Set `CHIEF_MACHINE_BUDGET=0` to opt out for a run; the registry record
and the run's `machine-budget.log` retain that choice.
