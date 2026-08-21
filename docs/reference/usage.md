# `chief usage`

`chief usage` reads existing event logs and reports one row per run. It never calls a
provider or writes state.

```text
chief usage [--days N] [--repo PATH|--scope PATH] [--json]
```

`--days N` keeps events from the last N days. `--repo PATH` (also `--scope`) includes
that repository and repositories below it, which makes a parent-directory report
possible. Without it, all logs on the host are included.

The JSON form is one document on stdout:

```json
{
  "chief": "usage",
  "scope": {"repo": null, "days": 7},
  "runs": [{
    "run_id": "…", "turns": 2,
    "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15, "cost_usd": 0.25},
    "limits": {"incidents": 1, "wait_seconds": 60, "last_reset_eta": 180}
  }],
  "total": {"turns": 2, "input_tokens": 10, "output_tokens": 5,
    "total_tokens": 15, "cost_usd": 0.25, "limit_incidents": 1,
    "wait_seconds": 60, "last_reset_eta": 180}
}
```

Unavailable provider measurements are `null` in JSON and empty in the fixed-width
human table; they are never reported as zero.
