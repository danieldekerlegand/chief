#!/usr/bin/env bash
#
# engine/mergequeue.sh — the OPT-IN batch merge queue.
#
# WHAT THIS IS NOT. It is not a replacement for the serialized merge floor. That
# floor — rebase onto the latest base, re-verify, merge `--no-ff`, one tasklist at a
# time — is chief's correctness guarantee, it stays the DEFAULT, and with this
# feature switched off the merge phase in driver.sh runs byte-for-byte as it always
# has. Nothing here is reached unless an operator asked for it.
#
# WHAT IT IS. A verification-amortization device, in the shape Bors and Gastown's
# "Refinery" have run for years: instead of paying the verify gate N times for N
# finished branches, STACK the branches (rebase each onto the running batch tip) and
# verify the resulting TIP ONCE. A green tip is a tree containing every member, so
# every member has had a green verify on a tree containing it — the same invariant
# the floor gives, bought once instead of N times.
#
# THE COST OF THAT TRADE, stated plainly: a batch tip is a single observation about N
# branches. When it is GREEN that is strictly stronger than N separate observations.
# When it is RED it says only "one of these is bad" and names none of them — so the
# tip is BISECTED (mq_bisect): binary-search the stacked prefixes for the smallest red
# one, confirm the branch it points at by re-verifying that branch ALONE on the base,
# blame it, merge the prefix the search proved green, and re-form a batch from the
# survivors. Worst case that is ceil(log2 N) + 1 extra gate runs instead of N.
#
# DETERMINISM IS THE ASSUMPTION, and the bisect is where it bites. Amortizing a gate
# across N branches is only sound when the gate is a deterministic function of the
# tree; a flaky gate makes the tip's verdict a coin flip about a SET rather than a
# fact about a TREE, and a bisect over coin flips blames an innocent branch with total
# confidence. Chief cannot make a gate deterministic. What it does instead is refuse
# to blame anything on the strength of ONE observation: every bisect verdict is put to
# a confirming run of the isolated branch by itself, and when the two disagree — a
# flaky gate, or a failure that is JOINT rather than any one branch's — the bisect is
# ABANDONED, every branch is restored, and the whole batch goes through the serialized
# floor. Correct, just slower. `MERGE_BATCH_BISECT=0` skips straight to that, which is
# the honest setting for a gate known to be flaky.
#
# ORDERING IS DETERMINISTIC, so a batch is reproducible: members are stacked in
# COMPLETION ORDER (the order their workers reached the merge phase), ties broken by
# tasklist name. Both are captured in the member record's filename — a zero-padded
# sequence minted under a lock, then the name — so a plain byte sort of the queue
# directory IS the batch order.
#
# THE LEADER/MEMBER PROTOCOL. There is no new scheduler state and no new process.
# A worker that reaches the merge phase with batching on ENQUEUES itself and then
# races for the existing $MERGE_LOCK, exactly as it races for it today:
#
#   · the winner is the BATCH LEADER. It waits (briefly, and only while a peer could
#     still join) for the queue to fill, CLAIMS a batch, and performs the whole
#     stack -> verify -> merge for every member, writing each member's status,
#     liveliness record and event as it goes.
#   · every other member polls for its own resolution and returns once the leader has
#     written it. A member that enqueued after the claim simply leads the next batch.
#
# So `chief ps`, dep_broken(), reap() and the summary see what they have always seen:
# a tasklist is `running` until its worker returns, and its <name>.status is what
# reap() maps to a scheduler state.
#
# A BATCH OF ONE IS THE SERIALIZED PATH. One member means: rebase it onto the base,
# verify that tree once, merge it --no-ff — the floor, reached through the same loop
# the batch uses, which is also why a tasklist that must not be batched (see
# mq_batchable) is simply given a batch of its own rather than a separate code path.
# The single `[ "$nstack" = 1 ]` in mq_run_batch is not a divergent path: it is the
# statement that a red tip covering ONE branch already names its culprit, so there is
# nothing to bisect and the floor's own VERIFY-FAILED arm applies verbatim. It is also
# the recursion's base case — which is why dissolving a batch cannot loop.
#
# Bash 3.2 only: no associative arrays, no `declare -A`, no process substitution.

# ---------------------------------------------------------------------------
# Settings + queue location
# ---------------------------------------------------------------------------
# MERGE_BATCH is the switch AND the bound: 1 (the default) means OFF, and any larger
# value is the maximum number of branches one batch may contain. Sanitized here
# rather than trusted: a garbled `.chief/config` value must degrade to the floor, not
# to an unbounded batch or a `[: integer expression expected` mid-merge.
mq_batch_max() {
  local n="${MERGE_BATCH:-1}" cap="${MERGE_BATCH_CAP:-16}"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  case "$cap" in ''|*[!0-9]*) cap=16 ;; esac
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt "$cap" ] && n="$cap"
  printf '%s' "$n"
}
mq_enabled() { [ "$(mq_batch_max)" -gt 1 ]; }

# How long a leader will WAIT for more members before closing the batch, in seconds.
# It waits only while a peer could still join (see mq_peer_could_join), so with
# PARALLEL=1 — where no peer ever can — it never waits at all and every batch is a
# batch of one. 0 disables waiting entirely: batch whatever already finished.
mq_wait_budget() {
  local n="${MERGE_BATCH_WAIT:-120}"
  case "$n" in ''|*[!0-9]*) n=120 ;; esac
  printf '%s' "$n"
}

mq_dir() { printf '%s' "$STATE/mq"; }
mq_init() { mkdir -p "$(mq_dir)" 2>/dev/null || true; }

# The number of verify-gate invocations this run's queue has spent, and the number of
# branches they covered. Recorded rather than asserted: "batching amortizes
# verification" is a claim about a ratio, and a claim about a ratio that nothing
# counts is a slogan. Read by the run summary and by test/.
mq_bump() {   # mq_bump COUNTER [BY]
  local f cur
  f="$(mq_dir)/$1"
  cur="$(cat "$f" 2>/dev/null || echo 0)"
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  printf '%s' "$(( cur + ${2:-1} ))" > "$f"
}
mq_count() {
  local c; c="$(cat "$(mq_dir)/$1" 2>/dev/null || echo 0)"
  case "$c" in ''|*[!0-9]*) c=0 ;; esac
  printf '%s' "$c"
}

# ---------------------------------------------------------------------------
# Eligibility — which finished branches may ride in a batch at all
# ---------------------------------------------------------------------------
# mq_batchable NAME BRANCH WORK_REPO WORK_BASE -> 0 = may join a batch.
#
# Two exclusions, both because the batch TIP cannot answer the question the floor
# answers per branch:
#
#   · a per-tasklist `"verify": [...]` array is that tasklist's OWN gate. A tip
#     shared with other branches is not the tree it was written about, and running
#     every member's array on every tip is the opposite of amortization.
#   · a branch that changes a domain declared an OVERLAP ZONE with policy `review`
#     (engine/zones.sh) needs a human's yes, and a batch-tip verify is not one. Such
#     a branch is never merged as a batch MEMBER — it takes the floor, where the
#     policy layer asks about it exactly as it does today.
#
# Ineligible is not a failure and not a park: it means "this one merges alone", which
# is a batch of one, which is the serialized path.
mq_batchable() {
  local name="$1" branch="$2" repo="$3" base="$4" conf files
  [ -z "$(jq -r '(.verify // [])[]' "$TASKS_DIR/$name.json" 2>/dev/null)" ] || return 1
  conf="${ZONES_CONF:-}"
  [ -n "$conf" ] || return 0
  files="$(git -C "$repo" diff --name-only "$base...$branch" 2>/dev/null)"
  [ -z "$(zones_match review "$conf" "$files" "$(touches_of "$name" | tr '\n' ' ')" 2>/dev/null)" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# The queue itself
# ---------------------------------------------------------------------------
# One file per merge-ready branch, named <seq>.<name>.member so that a byte sort of
# the directory is the documented batch order (completion order, ties by name). The
# record is one delimited line:
#
#     name  branch  work_repo  work_base  sub  original-tip-sha
#
# Fields are separated by US (0x1f), NOT by a tab. Tab is IFS *whitespace* to bash, so
# `read` collapses a run of them into one delimiter and drops empty fields — and `sub`
# is empty for every tasklist that is not a `repo:<submodule>` one, which is most of
# them. With a tab the sha would silently land in `sub`. A non-whitespace separator
# that cannot occur in a branch name or a path is the fix.
#
# The ORIGINAL TIP SHA is load-bearing, not bookkeeping. Stacking rewrites a member's
# branch onto its predecessors; if the batch is later dissolved, a branch left in that
# state carries commits belonging to peers that may never merge. Every dissolution
# path below restores each branch to this sha first.
MQ_FS="$(printf '\037')"    # US — the member record's field separator (see above)

mq_seq() {   # mint the next sequence number, serialized (bash 3.2, mkdir lock)
  local lock f cur w=0
  lock="$(mq_dir)/.seq.lock"; f="$(mq_dir)/.seq"
  while ! mkdir "$lock" 2>/dev/null; do sleep 1; w=$(( w + 1 )); [ "$w" -gt 60 ] && break; done
  cur="$(cat "$f" 2>/dev/null || echo 0)"; case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  cur=$(( cur + 1 )); printf '%s' "$cur" > "$f"
  rmdir "$lock" 2>/dev/null || true
  printf '%06d' "$cur"
}

mq_enqueue() {   # mq_enqueue NAME BRANCH REPO BASE SUB
  local name="$1" branch="$2" repo="$3" base="$4" sub="$5" seq sha
  mq_init
  sha="$(git -C "$repo" rev-parse "$branch" 2>/dev/null || echo)"
  seq="$(mq_seq)"
  printf '%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$name" "$MQ_FS" "$branch" "$MQ_FS" "$repo" "$MQ_FS" "$base" "$MQ_FS" "$sub" "$MQ_FS" "$sha" \
    > "$(mq_dir)/$seq.$name.member"
  : > "$(mq_dir)/$name.queued"
}

mq_is_queued()  { [ -f "$(mq_dir)/$1.queued" ]; }
mq_resolved()   { [ -f "$(mq_dir)/$1.done" ]; }
mq_resolve()    { rm -f "$(mq_dir)/$1.queued" 2>/dev/null || true; : > "$(mq_dir)/$1.done"; }

# Unclaimed members whose work repo AND base match the leader's. A batch is
# HOMOGENEOUS by construction: stacking branches from different repos, or aimed at
# different integration branches, is not a stack at all. Members that do not match
# stay queued and lead a batch of their own.
mq_candidates() {   # mq_candidates REPO BASE -> member FILES, one per line, in batch order
  local repo="$1" base="$2" f
  for f in "$(mq_dir)"/*.member; do
    [ -e "$f" ] || continue
    [ "$(cut -d"$MQ_FS" -f3 "$f")" = "$repo" ] || continue
    [ "$(cut -d"$MQ_FS" -f4 "$f")" = "$base" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

# Could any tasklist that is not already in the queue still reach it? Only a peer
# whose worker is still RUNNING can: a 'pending' one cannot launch while the leader
# holds a parallel slot, so counting it would make the leader wait out its whole
# wait budget for work that is itself waiting on the leader.
mq_peer_could_join() {
  local self="$1" n
  for n in $NAMES; do
    [ "$n" = "$self" ] && continue
    [ "$(get_state "$n")" = "running" ] || continue
    mq_is_queued "$n" && continue
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Per-member bookkeeping — what the floor writes for one branch, written by the
# leader on that branch's behalf. Four surfaces, together or not at all (the same
# rule as driver.sh's worker_park, which this delegates to where it can).
# ---------------------------------------------------------------------------
mq_member_log() {   # a pointer line into the member's OWN log; the detail is in the leader's
  local m="$1"; shift
  printf '%s\n' "$*" >> "$STATE/$m.log" 2>/dev/null || true
}

mq_member_park() {   # mq_member_park NAME KIND DETAIL MESSAGE  (worker_park by dynamic scope)
  local name="$1" kind="$2" detail="$3" msg="$4"
  local live total remaining
  live="$(live_of "$name")"
  total="$(jq '.userStories|length' "$TASKS_DIR/$name.json" 2>/dev/null || echo 0)"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  remaining=0
  worker_park "$kind" "$detail" "$msg"
  mq_member_log "$name" "$msg"
  mq_resolve "$name"
}

mq_member_fail() {   # mq_member_fail NAME PHASE STATUS EVENT DETAIL MESSAGE
  local name="$1" phase="$2" status="$3" ev="$4" detail="$5" msg="$6"
  live_set "$(live_of "$name")" phase="$phase"
  event_emit "$ev" name="$name" state=failed detail="$detail"
  printf '%s\n' "$status" > "$STATE/$name.status"
  printf '%s\n' "$msg"
  mq_member_log "$name" "$msg"
  mq_resolve "$name"
}

# ---------------------------------------------------------------------------
# The leader
# ---------------------------------------------------------------------------
# mq_stack_member — check out one member and rebase it onto the running TIP.
#   0 stacked (the branch is now the tip)   1 ejected (labelled, branch untouched)
#
# Every ejection arm below is the floor's arm, matched in label, forensics file and
# message: a batch must never invent a new way for a branch to fail. One bad rebase
# ejects ONE member; the batch re-forms without it and carries on.
mq_stack_member() {
  local name="$1" branch="$2" repo="$3" base="$4" tip="$5"
  local pre_mb rpt refusal rb_out rb_rc=0 conflicted
  git -C "$repo" checkout "$branch" >/dev/null 2>&1 || {
    mq_member_fail "$name" checkout-failed CHECKOUT-FAILED tasklist.checkout-failed \
      "git checkout $branch failed in $repo" "!! $name: could not check out $branch for the merge batch"
    return 1; }
  pre_mb="$(git -C "$repo" merge-base "$branch" "$base" 2>/dev/null || echo)"
  refusal="$(rebase_refusal_cause "$repo")"
  if [ -z "$refusal" ] && git -C "$repo" merge-base --is-ancestor "$tip" "$branch" 2>/dev/null; then
    echo ">> batch: $name ($branch) is strictly ahead of the tip — rebase is a no-op, skipping it"
  elif [ -z "$refusal" ]; then
    rb_out="$(git -C "$repo" rebase "$tip" 2>&1)" || rb_rc=$?
    if [ "$rb_rc" != 0 ]; then
      conflicted="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null)"
      if [ -n "$conflicted" ]; then
        rpt="$SNAP/$name.rebase-conflict.md"
        conflict_report "$name" "$branch" "$repo" "$base" "$pre_mb" "REBASE-CONFLICT" "$rpt"
        rm -f "$SNAP/$name.merge-conflict.md" "$SNAP/$name.rebase-refused.md" 2>/dev/null || true
        git -C "$repo" rebase --abort 2>/dev/null || true
        mq_member_fail "$name" rebase-conflict "REBASE-CONFLICT see $SNAP_REL/$name.rebase-conflict.md" \
          tasklist.rebase-conflict "onto the merge-batch tip; forensics: $rpt" \
          "!! $name rebase conflict onto the batch tip — EJECTED from the batch and left for manual merge; what collided and with whom: $rpt"
        return 1
      fi
      refusal="$(printf '%s\n' "$rb_out" | sed -e 's/^[[:space:]]*//' -e '/^$/d' \
                   -e 's/^error: //' -e 's/^fatal: //' | head -3 | tr '\n' ' ' \
                   | sed -e 's/  */ /g' -e 's/ *$//' | cut -c1-200)"
      [ -n "$refusal" ] || refusal="$(rebase_refusal_cause "$repo")"
      [ -n "$refusal" ] || refusal="git rebase exited $rb_rc, left no conflicted paths, and printed nothing"
      git -C "$repo" rebase --abort 2>/dev/null || true
    fi
  fi
  if [ -n "$refusal" ]; then
    rpt="$SNAP/$name.rebase-refused.md"
    refusal_report "$name" "$branch" "$repo" "$base" "$refusal" "$rpt"
    rm -f "$SNAP/$name.rebase-conflict.md" "$SNAP/$name.merge-conflict.md" 2>/dev/null || true
    mq_member_fail "$name" rebase-refused "REBASE-REFUSED $refusal (see $SNAP_REL/$name.rebase-refused.md)" \
      tasklist.rebase-refused "$refusal" \
      "!! $name: git REFUSED to rebase $branch onto the batch tip — EJECTED, nothing merged, branch untouched: $refusal"
    return 1
  fi
  return 0
}

# mq_merge_member — the floor's own merge step for one already-verified branch:
# ask the policy layer, then `--no-ff` into the base, then finalize. Merge ordering
# stays SERIALIZED against the base — the batch amortized the VERIFY, it never makes
# concurrent writes to the integration branch.
mq_merge_member() {
  local name="$1" branch="$2" repo="$3" base="$4" sub="$5" pre_mb="$6" sha rpt af
  local live; live="$(live_of "$name")"
  git -C "$repo" checkout "$branch" >/dev/null 2>&1 || {
    mq_member_fail "$name" checkout-failed CHECKOUT-FAILED tasklist.checkout-failed \
      "git checkout $branch failed in $repo" "!! $name: could not check out $branch to merge it"
    return 1; }
  # THE POLICY LAYER, per BRANCH and never per batch tip — which is the whole point of
  # doing it here, with this member's branch checked out: the diff-size budget it folds
  # in measures THIS branch's stories, so a batch can never dilute an oversized diff
  # into an aggregate that clears the budget.
  if ! zones_merge_gate "$name" "$branch" "$repo" "$base" "$STATE" \
                        "$(touches_of "$name" | tr '\n' ' ')"; then
    mq_member_park "$name" awaiting-approval \
      "the merge policy layer (overlap zone / diff budget) — rebased + verified, held for a human" \
      "   Branch $branch is kept (rebased, green) — approve what no gate can check, then re-run:  chief approve $name && chief run"
    return 1
  fi
  live_set "$live" phase=merging
  git -C "$repo" checkout "$base" >/dev/null 2>&1
  if git -C "$repo" merge --no-ff "$branch" -m "Merge $branch (chief, auto-verified)"; then
    sha="$(git -C "$repo" rev-parse --short HEAD)"
    finalize_merged "$name" "$branch" "$sha" "$repo" "$sub"
    rm -f "$SNAP/$name.verify-failed.log" "$SNAP/$name.rebase-conflict.md" \
          "$SNAP/$name.merge-conflict.md" "$SNAP/$name.rebase-refused.md" \
          "$(zones_request_file "$STATE" "$name")" "$(zones_approval_file "$STATE" "$name")" 2>/dev/null || true
    live_set "$live" phase=merged story=
    event_emit tasklist.merged name="$name" state=done detail="$branch --no-ff into $base @$sha${sub:+ ($sub)} (merge batch)"
    printf 'MERGED @%s%s\n' "$sha" "${sub:+ ($sub)}" > "$STATE/$name.status"
    echo ">> $name MERGED @$sha${sub:+ in $sub} (merge batch)"
    mq_member_log "$name" ">> $name MERGED @$sha${sub:+ in $sub} — merged as part of a verified merge batch"
    af="$(audit_findings "$name")"; [ -n "$af" ] && printf '%s\n' "$af"
    mq_resolve "$name"
    return 0
  fi
  rpt="$SNAP/$name.merge-conflict.md"
  conflict_report "$name" "$branch" "$repo" "$base" "$pre_mb" "MERGE-CONFLICT" "$rpt"
  rm -f "$SNAP/$name.rebase-conflict.md" "$SNAP/$name.rebase-refused.md" 2>/dev/null || true
  git -C "$repo" merge --abort 2>/dev/null || true
  mq_member_fail "$name" merge-conflict "MERGE-CONFLICT see $SNAP_REL/$name.merge-conflict.md" \
    tasklist.merge-conflict "merging into $base; forensics: $rpt" \
    "!! $name merge conflict — what collided and with whom: $rpt"
  return 1
}

# mq_verify_tip — the one verification a batch buys, counted as it is spent.
# NAME is the tip member's, which is what run_verify keys its (absent, by
# mq_batchable) per-tasklist array off. LOG is where a red tip's output is persisted:
# for a batch of ONE that is the floor's own $SNAP/<name>.verify-failed.log — the file
# the next run reads to re-engage the agent — and for a real batch it is the anonymous
# tip log, because a red tip is not yet about any one branch.
mq_verify_tip() {
  local name="$1" repo="$2" work_base="$3" covered="$4" log="$5" vout vrc=0
  # `covered` counts branches a gate was ASKED about; `verifications` counts gates
  # actually run. Under NO_VERIFY=1 the second must stay 0 — reporting a verification
  # that never happened is exactly the kind of claim this counter exists to replace.
  mq_bump covered "$covered"
  [ "$NO_VERIFY" = "1" ] && { echo ">> batch: verify skipped (NO_VERIFY=1)"; return 0; }
  mq_bump verifications
  echo ">> batch: verifying the batch TIP once for $covered branch(es) — verification #$(mq_count verifications) this run"
  vout="$(run_verify "$repo" "$name" 2>&1)"; vrc=$?
  printf '%s\n' "$vout"
  [ "$vrc" = 0 ] && return 0
  printf '%s\n' "$vout" > "$log"
  return 1
}

# ---------------------------------------------------------------------------
# The bisect — turning "one of these N is bad" into "THIS one is bad"
# ---------------------------------------------------------------------------
# A red tip is a single observation about N branches: it says one of them is bad and
# names none of them. Discarding the whole batch for it is correct but throws away the
# reason to batch at all, so chief does what Bors and Gastown's Refinery do — BISECT.
#
# THE SEARCH SPACE IS ALREADY BUILT. Member k's branch was rebased onto member k-1, so
# member k's branch IS the tip of the first k branches. Probing a prefix costs one
# checkout and one gate run; nothing is re-stacked. Binary search for the SMALLEST red
# prefix and its last branch is the one whose arrival broke the stack.
#
# HOW MANY EXTRA VERIFICATIONS THAT COSTS, stated honestly: ceil(log2 N) probes plus
# one confirming run, on top of the tip. For N=8 that is 1+3+1 = 5 against the floor's
# 8, and the survivors' batch makes it 6 — a win. For N=3 it is 5 against 3, a loss.
# Bisect pays off as batches grow; it is not free, and the counters in the run summary
# report what it actually cost rather than what it was supposed to.

# How many branches ONE batch may isolate before chief stops bisecting and pays the
# floor. Each isolation costs a fresh round, so a batch with many bad members is
# cheaper re-run serially than bisected repeatedly; this bound is what makes a
# pathological batch DEGRADE instead of loop. 0 disables bisect entirely — the honest
# setting for a gate known to be flaky, where the floor is the only sound answer.
mq_bisect_max() {
  local n="${MERGE_BATCH_BISECT:-2}"
  case "$n" in ''|*[!0-9]*) n=2 ;; esac
  printf '%s' "$n"
}

# mq_verify_at NAME BRANCH REPO WORK_BASE LOG LABEL
#   0 = green   1 = red (output persisted to LOG)   2 = could not even check out
# Every gate run here is an EXTRA one — the price of isolating a culprit — so it is
# counted apart from the batch tips (`probes`) and the summary reports both. WORK_BASE
# is a local on purpose: run_verify reads $work_base from its caller's scope.
mq_verify_at() {
  local name="$1" branch="$2" repo="$3" work_base="$4" log="$5" label="$6" vout vrc=0
  git -C "$repo" checkout "$branch" >/dev/null 2>&1 || return 2
  [ "$NO_VERIFY" = "1" ] && return 0
  mq_bump probes
  echo ">> batch: $label — extra gate run #$(mq_count probes) spent isolating a culprit"
  vout="$(run_verify "$repo" "$name" 2>&1)"; vrc=$?
  printf '%s\n' "$vout"
  [ "$vrc" = 0 ] && return 0
  [ -n "$log" ] && printf '%s\n' "$vout" > "$log"
  return 1
}

# mq_bisect KEPT N REPO WORK_BASE — binary search for the smallest RED prefix.
# Sets MQ_CULPRIT to that prefix's 1-based index and returns 0; returns 1 if the
# search could not be completed at all (abandon, and pay the floor).
#
# Two facts bound the search and both are OBSERVED, never assumed:
#   · prefix N is RED   — that is why we are here (mq_verify_tip just said so);
#   · prefix `lo-1` is GREEN — `lo` only ever advances past a prefix a gate just passed.
# Prefix 0 is the base branch, taken as green because the floor put it there green.
# So at exit the culprit's predecessors carry a real green observation, which is what
# lets the caller merge them without re-verifying: the invariant is that nothing
# reaches the base without a green gate run on a tree containing it, and that prefix
# had one.
MQ_CULPRIT=0
mq_bisect() {
  local kept="$1" n="$2" repo="$3" work_base="$4" lo=1 hi mid rec name branch rc
  hi="$n"; MQ_CULPRIT=0
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    rec="$(sed -n "${mid}p" "$kept")"
    name="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f1)"
    branch="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f2)"
    rc=0
    mq_verify_at "$name" "$branch" "$repo" "$work_base" "$SNAP/.batch-bisect.verify-failed.log" \
      "BISECT: the first $mid of $n stacked branch(es), tip $branch" || rc=$?
    case "$rc" in
      0) echo ">> batch:   the first $mid branch(es) are GREEN together"; lo=$(( mid + 1 )) ;;
      1) echo "!! batch:   the first $mid branch(es) are RED together";   hi="$mid" ;;
      *) echo "!! batch:   could not check out $branch to probe the stack"; return 1 ;;
    esac
  done
  MQ_CULPRIT="$lo"
  echo ">> batch: BISECT points at member #$MQ_CULPRIT of $n — $(sed -n "${MQ_CULPRIT}p" "$kept" | cut -d"$MQ_FS" -f1)"
  return 0
}

# mq_confirm_culprit REC REPO WORK_BASE — the second observation, without which no
# branch is ever blamed.
#
# The bisect's verdict is an inference from ONE reading of a SHARED tree, and it is
# sound only while the gate is a deterministic function of that tree. So before a
# branch is labelled, chief puts it in exactly the position the serialized floor would
# have: restored to the sha its worker finished on, rebased onto the base ALONE, and
# verified. Red again = confirmed, and the branch is left in the floor's own
# VERIFY-FAILED state, its log written where the next run looks for it.
#
# Green = the two observations DISAGREE. Either the gate is flaky, or the failure is
# JOINT — this branch is fine by itself and only breaks in combination with a peer it
# was stacked on. Neither is a licence to blame it, so the caller abandons the bisect
# and re-runs every member through the floor, where a joint failure resolves itself
# correctly: the first branch merges, the second meets it ON the base and fails there,
# attributably.
#   0 = confirmed (this branch is the culprit)   1 = not confirmed (abandon)
mq_confirm_culprit() {
  local rec="$1" repo="$2" work_base="$3" name branch sha rc=0
  name="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f1)"
  branch="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f2)"
  sha="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f6)"
  echo ">> batch: CONFIRMING $name ($branch) alone on $work_base before blaming it for the red tip"
  # Off the branch before moving it — the bisect's last probe left HEAD ON it, and a
  # `git branch -f` against the checked-out branch fails. Silently, in the shape this
  # function is written: the branch would stay STACKED, the "isolated" verify would be
  # a second reading of the very tree the bisect already read, and a joint failure
  # would be confirmed as a single branch's fault. So the move is checked, not hoped.
  git -C "$repo" checkout "$work_base" >/dev/null 2>&1
  [ -n "$sha" ] && git -C "$repo" branch -f "$branch" "$sha" >/dev/null 2>&1
  if [ -n "$sha" ] && [ "$(git -C "$repo" rev-parse "$branch" 2>/dev/null)" != "$sha" ]; then
    echo "!! batch: $branch could not be put back on the sha its worker finished on — the bisect is unconfirmable"
    return 1
  fi
  git -C "$repo" checkout "$branch" >/dev/null 2>&1 || {
    echo "!! batch: could not check out $branch to confirm the bisect"; return 1; }
  if ! git -C "$repo" merge-base --is-ancestor "$work_base" "$branch" 2>/dev/null; then
    git -C "$repo" rebase "$work_base" >/dev/null 2>&1 || {
      git -C "$repo" rebase --abort 2>/dev/null || true
      echo "!! batch: $branch could not be rebased onto $work_base alone — the bisect is unconfirmable"; return 1; }
  fi
  mq_verify_at "$name" "$branch" "$repo" "$work_base" "$SNAP/$name.verify-failed.log" \
    "CONFIRM: $branch alone on $work_base" || rc=$?
  case "$rc" in
    1) echo ">> batch: CONFIRMED — $branch fails on its own; it is the culprit"; return 0 ;;
    0) echo "!! batch: NOT CONFIRMED — $branch is GREEN alone on $work_base though the stack containing it was RED." ;;
    *) echo "!! batch: NOT CONFIRMED — $branch could not be verified alone." ;;
  esac
  return 1
}

# mq_blame REC — the floor's VERIFY-FAILED arm, written for an isolated batch member.
# Same label, same status string, same event, same persisted log: an isolated culprit
# is left in EXACTLY the state a serialized failure leaves it in, which is what makes
# it eligible for the existing bounded re-arm on the next run with no new plumbing.
mq_blame() {
  local rec="$1" name branch
  name="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f1)"
  branch="$(printf '%s' "$rec" | cut -d"$MQ_FS" -f2)"
  mq_member_fail "$name" verify-failed "VERIFY-FAILED" tasklist.verify-failed \
    "verify failed on $branch alone, isolated by a batch bisect; log: $SNAP_REL/$name.verify-failed.log" \
    "!! $name verify failed — ISOLATED by the batch bisect and left exactly as a serialized failure leaves it (persisted for re-engagement)"
}

# mq_restore — put every branch back exactly as its worker left it. Called at the top
# of every batch ROUND and on every path that DISSOLVES a batch, before anything else
# happens: a member whose branch still sits on top of a peer that may never merge is a
# branch carrying work it did not do, and rebasing THAT onto the base would replay the
# peer's commits with it. A branch already at its worker's sha is left alone, silently.
mq_restore() {
  local recs="$1" name branch repo sha base
  repo="$(head -1 "$recs" | cut -d"$MQ_FS" -f3)"
  base="$(head -1 "$recs" | cut -d"$MQ_FS" -f4)"
  # Get OFF any member branch first. `git branch -f` refuses to move the branch that
  # is currently checked out — and it refuses quietly, which would leave a member
  # still stacked on a peer while this function cheerfully reported it restored.
  [ -n "$repo" ] && git -C "$repo" checkout "$base" >/dev/null 2>&1
  while IFS="$MQ_FS" read -r name branch repo _ _ sha; do
    [ -n "$branch" ] && [ -n "$sha" ] || continue
    [ "$(git -C "$repo" rev-parse "$branch" 2>/dev/null)" = "$sha" ] && continue
    git -C "$repo" branch -f "$branch" "$sha" >/dev/null 2>&1 || true
    echo ">> batch: restored $name ($branch) to the sha its worker finished on"
  done < "$recs"
}

# mq_merge_all RECS REPO WORK_BASE — the floor's merge step for each member in order.
mq_merge_all() {
  local recs="$1" repo="$2" work_base="$3" name branch sub pre_mb
  while IFS="$MQ_FS" read -r name branch _ _ sub _; do
    [ -n "$name" ] || continue
    pre_mb="$(git -C "$repo" merge-base "$branch" "$work_base" 2>/dev/null || echo)"
    mq_merge_member "$name" "$branch" "$repo" "$work_base" "$sub" "$pre_mb" || true
  done < "$recs"
}

# mq_dissolve RECS REPO WORK_BASE REASON — give up on the batch and pay the floor.
# Restore every branch to the sha its worker finished on FIRST (a branch left stacked
# carries commits belonging to peers that may never merge), then re-run each member as
# a batch of ONE — which is the serialized path, reached through the same loop.
mq_dissolve() {
  local recs="$1" repo="$2" work_base="$3" reason="$4" one rec
  echo "!! batch: $reason"
  echo "!! batch: DISSOLVING — every branch goes back to the sha its worker finished on and through the serialized floor, one verify each."
  mq_bump dissolved
  git -C "$repo" checkout "$work_base" >/dev/null 2>&1 || true
  mq_restore "$recs"
  one="$recs.solo"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    printf '%s\n' "$rec" > "$one"
    mq_run_batch "$one"
  done < "$recs"
  rm -f "$one"
}

# mq_run_batch RECS — the leader's whole job, with $MERGE_LOCK held.
#
#   STACK  ->  VERIFY THE TIP ONCE  ->  merge every member.
#   A red tip  ->  BISECT  ->  merge the prefix the bisect PROVED green, blame the one
#                  branch a confirming run agreed about, re-form a batch from the
#                  survivors (they have never been verified without it) and go round.
#
# A BATCH OF ONE IS THE SERIALIZED PATH, on every arm: stack it on the base, verify
# that tree, merge it --no-ff — and a red tip on a batch of one is simply that
# branch's own VERIFY-FAILED, with the same label and the same log the floor writes.
# That is also the recursion's base case, which is why dissolving cannot loop.
#
# TERMINATION. Every round either ends the batch or removes at least one member from
# `pending` (the culprit is blamed, its proven-green predecessors are merged), so the
# loop is finite on its own; the mq_bisect_max bound is the tighter one, capping how
# many isolations are worth paying for before the floor is simply cheaper.
mq_run_batch() {
  local recs="$1"
  local repo work_base pending kept tag rounds max_rounds rec
  local name branch sub sha tip nstack tiplog i left
  repo="$(head -1 "$recs" | cut -d"$MQ_FS" -f3)"
  work_base="$(head -1 "$recs" | cut -d"$MQ_FS" -f4)"
  max_rounds="$(mq_bisect_max)"; rounds=0
  mq_bump depth; tag="$$.$(mq_count depth)"
  pending="$(mq_dir)/.pending.$tag"; kept="$(mq_dir)/.stacked.$tag"
  cp "$recs" "$pending"
  while [ -s "$pending" ]; do
    # Every round starts from the shas the WORKERS finished on. A survivor of an
    # earlier round is still sitting on top of a branch that was just blamed, and
    # rebasing THAT onto the base would replay the culprit's commits with it.
    mq_restore "$pending"
    tip="$work_base"; : > "$kept"; nstack=0
    while IFS="$MQ_FS" read -r name branch _ _ sub sha; do
      [ -n "$name" ] || continue
      live_set "$(live_of "$name")" phase=batch-stacking
      if mq_stack_member "$name" "$branch" "$repo" "$work_base" "$tip"; then
        printf '%s%s%s%s%s%s%s%s%s%s%s\n' \
          "$name" "$MQ_FS" "$branch" "$MQ_FS" "$repo" "$MQ_FS" "$work_base" "$MQ_FS" "$sub" "$MQ_FS" "$sha" >> "$kept"
        tip="$branch"; nstack=$(( nstack + 1 ))
      fi
    done < "$pending"
    : > "$pending"
    if [ "$nstack" = 0 ]; then
      echo ">> batch: every member was ejected before it could be stacked — nothing to verify"
      break
    fi
    echo ">> batch: stacked $nstack branch(es) on $work_base — tip is $tip"
    # ONE verification for the whole stack. $tip is checked out (the last successful
    # rebase left it there), so this is a gate run on a tree containing every member.
    name="$(tail -1 "$kept" | cut -d"$MQ_FS" -f1)"
    tiplog="$SNAP/.batch-tip.verify-failed.log"
    [ "$nstack" = 1 ] && tiplog="$SNAP/$name.verify-failed.log"
    if mq_verify_tip "$name" "$repo" "$work_base" "$nstack" "$tiplog"; then
      mq_merge_all "$kept" "$repo" "$work_base"
      break
    fi
    # ---- RED TIP ------------------------------------------------------------
    if [ "$nstack" = 1 ]; then
      # One member, one observation, and it is about a tree containing nothing else.
      # This IS the floor's verify failure, so it gets the floor's arm verbatim.
      mq_blame "$(cat "$kept")"
      break
    fi
    echo "!! batch: the tip verify FAILED for $nstack stacked branch(es) — a red tip names no culprit, so go and find one."
    rounds=$(( rounds + 1 ))
    if [ "$rounds" -gt "$max_rounds" ]; then
      mq_dissolve "$kept" "$repo" "$work_base" \
        "this batch has already had $max_rounds branch(es) isolated and is STILL red — past the bound (MERGE_BATCH_BISECT=$max_rounds), the floor is cheaper than more bisecting"
      break
    fi
    if ! mq_bisect "$kept" "$nstack" "$repo" "$work_base"; then
      mq_dissolve "$kept" "$repo" "$work_base" "the bisect could not be completed"
      break
    fi
    i="$MQ_CULPRIT"
    rec="$(sed -n "${i}p" "$kept")"
    if ! mq_confirm_culprit "$rec" "$repo" "$work_base"; then
      mq_dissolve "$kept" "$repo" "$work_base" \
        "the bisect pointed at member #$i but a confirming re-verification of it ALONE disagreed — one observation is not a verdict, and a wrong branch is not blamed on the strength of it"
      break
    fi
    # Counted HERE and not in mq_blame: `isolated` is the number of branches a BISECT
    # picked out of a batch, and a batch of one that fails its own verify was never
    # isolated from anything — it is the floor's plain failure, borrowing the same arm.
    mq_bump isolated
    mq_blame "$rec"
    # The predecessors carry a real green observation (the bisect passed the gate on
    # the prefix that ends at member i-1), so they merge on that — not on a guess.
    if [ "$i" -gt 1 ]; then
      sed -n "1,$(( i - 1 ))p" "$kept" > "$kept.green"
      echo ">> batch: merging the $(( i - 1 )) branch(es) the bisect PROVED green together"
      mq_merge_all "$kept.green" "$repo" "$work_base"
      rm -f "$kept.green"
    fi
    # The survivors have never been verified WITHOUT the branch just isolated, so they
    # go round as a fresh batch rather than being merged on the strength of a tip that
    # contained it. That is the documented choice: re-form, do not merge blind.
    sed -n "$(( i + 1 )),\$p" "$kept" > "$pending"
    left="$(grep -c . "$pending" 2>/dev/null || echo 0)"
    [ "$left" -gt 0 ] && echo ">> batch: RE-FORMING a batch from the $left surviving branch(es)"
  done
  rm -f "$pending" "$kept"
  return 0
}

# ---------------------------------------------------------------------------
# The worker's entry point — replaces the serialized merge phase when batching is on
# ---------------------------------------------------------------------------
# mq_worker_merge NAME BRANCH WORK_REPO WORK_BASE SUB WT
#
# Enqueue, then race for $MERGE_LOCK exactly as the floor does. The winner leads a
# batch; everyone else waits for the leader to write their result. Always returns 0:
# by the time it does, this tasklist's <name>.status has been written by whoever
# resolved it, and reap() reads it exactly as it reads the floor's.
mq_worker_merge() {
  local name="$1" branch="$2" repo="$3" base="$4" sub="$5" wt="$6"
  local live; live="$(live_of "$name")"
  mq_init
  # Free the branch from its worktree BEFORE enqueuing: a leader cannot check out a
  # branch another worktree holds, and this worker is done with it either way.
  wt_git remove --force "$wt" 2>/dev/null || true
  mq_enqueue "$name" "$branch" "$repo" "$base" "$sub"
  live_set "$live" phase=merge-queued story=
  event_emit tasklist.queued name="$name" state=running detail="merge queue — max batch $(mq_batch_max)"
  echo ">> $name is merge-ready and QUEUED for the batch merge queue (max batch $(mq_batch_max))"
  while :; do
    mq_resolved "$name" && break
    if mkdir "$MERGE_LOCK" 2>/dev/null; then
      (
        # CRITICAL SECTION, on the same terms as the floor's: from here the work repo
        # is mid git operation, and the marker tells teardown to wait it out and names
        # the repo + base to restore if the wait is spent.
        trap 'git -C "$repo" checkout "$base" >/dev/null 2>&1 || true; rm -f "$STATE/$name.critical" 2>/dev/null' EXIT
        { echo "name=$name"; echo "repo=$repo"; echo "base=$base"; } > "$STATE/$name.critical" 2>/dev/null || true
        mq_lead "$name" "$repo" "$base"
      )
      rmdir "$MERGE_LOCK" 2>/dev/null || true
      mq_resolved "$name" && break
      # Led a batch this tasklist was not claimed into (it enqueued after the claim,
      # or its repo/base did not match the leader's): go round and lead the next one.
    fi
    sleep 2
    live_set "$live"
  done
  rm -f "$(mq_dir)/$name.done" 2>/dev/null || true
  return 0
}

# mq_lead SELF REPO BASE — wait for the batch to fill, claim it, run it.
mq_lead() {
  local self="$1" repo="$2" base="$3" max waited budget claim n f
  max="$(mq_batch_max)"; budget="$(mq_wait_budget)"; waited=0
  while [ "$(mq_candidates "$repo" "$base" | wc -l | tr -d ' ')" -lt "$max" ]; do
    [ "$waited" -ge "$budget" ] && break
    mq_peer_could_join "$self" || break
    sleep 2; waited=$(( waited + 2 ))
  done
  claim="$(mq_dir)/.batch.$$"
  : > "$claim"
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$n" -ge "$max" ] && break
    # CLAIM by removing the member file: anything that enqueues from here on belongs
    # to the NEXT batch, so a member can never be run by two leaders.
    cat "$f" >> "$claim" && rm -f "$f"
    n=$(( n + 1 ))
  done <<EOF
$(mq_candidates "$repo" "$base")
EOF
  if [ "$n" = 0 ]; then rm -f "$claim"; return 0; fi
  echo ">> batch: $self is leading a merge batch of $n branch(es)$( [ "$waited" -gt 0 ] && printf ' (waited %ss for peers)' "$waited" ):"
  cut -d"$MQ_FS" -f1 "$claim" | sed 's/^/     · /'
  mq_run_batch "$claim"
  rm -f "$claim"
  return 0
}
