# Host-wide concurrency

`-p N` limits tasklists within one `chief run`; it is not a machine-wide CPU
budget. Every run reads the existing `~/.chief/runs/` registry before launching
an agent turn. Live agent phases across all repositories count against
`CHIEF_MACHINE_BUDGET`, whose default is the detected physical-core count.

When the budget is full, the scheduler holds pending work and prints
`machine budget hold` until another run finishes. `chief ps` marks ready work as
`budget-hold` (rather than dependency-blocked `pending`) and gives the reason.
It does not kill work already in flight. `chief ps` also reports the one-minute
load average against physical cores and marks the machine `OVERSUBSCRIBED` when
that load is higher than the core count. On the incident host, five runs drove
load average to 62 on 14 physical cores (4.4x oversubscribed); check this line
before treating a long gate as a repository failure. A budget-waiting record is
quiet by design, so monitor's stall threshold does not flag it as hung while it
waits. Set `CHIEF_MACHINE_BUDGET=0` to opt out for a run; the registry record
and the run's `machine-budget.log` retain that choice.
