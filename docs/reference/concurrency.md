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

## The gate budget

An agent turn is provider latency; a **gate** — rebase, build, full test suite — is
the compute. `CHIEF_MACHINE_GATE_BUDGET` is the separate host-wide limit on gates,
defaulting to **2**: a repo that caps its own build at half the host's cores (as
cuneiform's `jobs = 7` does, on 14) saturates the machine at two concurrent gates
whatever the core count, so the default is the reciprocal of that share rather than
a fraction of the cores. It is enforced where a gate BEGINS — the agent-boundary
verify and the merge phase — never by interrupting one already running, because an
interrupted gate is a corrupt verdict and a wasted rebuild. A held worker publishes
the phase `gate-budget-waiting` and writes its reason to the run's
`machine-budget.log`.

It cannot deadlock, on two independent floors: a host with no gates running admits
one however small the budget, and any single hold is bounded by
`CHIEF_MACHINE_GATE_HOLD_MAX` (default 1800s), after which the gate starts anyway
and says so. `CHIEF_MACHINE_GATE_BUDGET=0` (or `off`) disables it; that is a
separate switch from `CHIEF_MACHINE_BUDGET=0`, which still governs agent turns.
