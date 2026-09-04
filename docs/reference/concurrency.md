# Host-wide concurrency

> **Status:** Current · **Updated:** 2026-09-04 · **Owner:** chief

`-p N` limits tasklists within one `chief run`; it is not a machine-wide CPU
budget. Every run reads the existing `~/.chief/runs/` registry before launching
an agent turn. Live agent phases across all repositories count against
`CHIEF_MACHINE_BUDGET`, whose default is the detected physical-core count.

When the budget is full, the scheduler holds pending work and prints
`machine budget hold` until another run finishes. `chief ps` marks ready work as
`budget-hold` (rather than dependency-blocked `pending`) and gives the reason.
It does not kill work already in flight. `chief ps` also reports the one-minute
load average against physical cores, and marks the machine `OVERSUBSCRIBED` where
that reading actually refused a gate (see *The model, in one place* below). On the
incident host, five runs drove load average to 62 on 14 physical cores (4.4x
oversubscribed); check this line before treating a long gate as a repository
failure. A budget-waiting record is
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

## The load ceiling

Both budgets above count chief's own registry records, so a host carrying an
operator's build, a browser and a VM reads to them as idle. `CHIEF_MACHINE_LOAD_LIMIT`
is the third input and the only one that sees work chief did not start: when the
one-minute load average is above it, no run is launched and no gate is admitted.
It defaults to the physical-core count — the same line `chief ps` already draws
against — and the number is now the decision rather than the decoration beside it.
One function samples it (`chief_machine_load_sample`, writing
`CHIEF_MACHINE_LOAD_AVERAGE`); the display line, the admission predicate
and the hold reason all read that global, because a second sampling path is how a
display and a decision come to disagree about the same machine.

It is **bounded, not absolute**. Load chief did not cause is load chief cannot
clear, so a rule that simply waits for the number to fall can wait forever while
chief itself is idle. Chief therefore defers to the load line only while it is
CONTRIBUTING to it: with no gate of chief's in flight, work is admitted whatever
the load says. That is the same floor the gate budget stands on, so a cleared host
always moves whichever control is consulted, and a gate hold remains bounded by
`CHIEF_MACHINE_GATE_HOLD_MAX` on top of it. `CHIEF_MACHINE_LOAD_LIMIT=0` (or `off`)
disables load-based admission entirely, for the operator who knows the load is
foreign; it is a third switch, separate from `CHIEF_MACHINE_BUDGET=0` and from
`CHIEF_MACHINE_GATE_BUDGET=0`, and turning any one of them off leaves the other
two doing their jobs.

## The model, in one place

Three controls, three resources. They are separate knobs because they govern
different things, and the defect this file documents was one number standing in for
all three.

| Control | Governs | Default | Off with |
|---|---|---|---|
| `CHIEF_MACHINE_BUDGET` | simultaneous **agent turns** host-wide | physical cores | `=0` |
| `CHIEF_MACHINE_GATE_BUDGET` | simultaneous **gates** host-wide | `2` | `=0` |
| `CHIEF_MACHINE_LOAD_LIMIT` | the machine's **one-minute load average** | physical cores | `=0` |

**Why an agent turn and a gate are budgeted apart.** An agent turn is dominated by
`provider-waiting` — network latency; the phase table gives it a 900s staleness
threshold for exactly that reason. A gate — rebase, build, full test suite — is the
compute. Budgeting turns against the core count therefore limits the cheap resource
with a number derived from the expensive one, which is how a 14-core host reached
load average 14.32 with five turns live and nine slots still nominally free. Collapse
the two back into one and that reading returns, whichever unit the survivor is in.

**Why the load ceiling is bounded rather than absolute.** It is the only input that
sees work chief did not start, and therefore the only one chief cannot clear by
waiting. Chief defers to it only while a gate of chief's own is in flight; with none,
work is admitted whatever the number says. That is the same zero-gates floor the gate
budget stands on, so both controls share one no-deadlock argument.

**What `chief ps` reports, and why it is two lines.** *Machine activity* is what is
running, each count against the budget it spends (`5/14 agent turn(s) · 1/2
gate(s)`). *Headroom* is what admission would do about one more — the admission
answer, not the subtraction, so a control that is currently refusing reports `0`
however much of its own budget is unspent, and names what is holding. `OVERSUBSCRIBED`
is spent only where the ceiling actually refused a gate; over the ceiling with chief
idle reads `over ceiling — admitting, no chief gate in flight`, because an alarm on a
machine chief is admitting work onto is an alarm an operator learns to ignore.

**Two machine holds, two rows.** The launch loop's hold is work that has not started
(`budget-hold`, phase `machine-budget-waiting`); the gate boundary's is a live worker
stopped before it begins its gate (`gate-hold`, phase `gate-budget-waiting`). Neither
is dependency-blocked `pending`, both are quiet by design, and both write their reason
and counts to the run's `machine-budget.log`.

**Scope.** These are host-wide *admission* controls, and they are the only line of
their kind chief draws. A repo's own contention settings — cargo's `jobs`, npm's
concurrency, a project's `verify.sh` — belong to that repo and are never read or
rewritten from here; the host-wide budget is the thing a per-repo cap like
cuneiform's `jobs = 7` has always assumed exists outside itself.
