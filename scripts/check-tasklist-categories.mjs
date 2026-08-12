#!/usr/bin/env node
/**
 * Tasklist-category guard — the execution-order rule, made machine-checkable.
 *
 * Every ACTIVE tasklist declares which of four kinds of work it is, and the
 * program runs them in that order: repair what is broken, unblock what is
 * stuck, replace what an OSS project already does, and only then build
 * something new.
 *
 *   fix      repairs a known defect in behaviour that already exists
 *   unblock  a refactor / gate / decision whose VALUE is enabling other
 *            tasklists — it ships no end-user capability of its own
 *   replace  retires hand-built code in favour of a well-maintained OSS
 *            project (including the validation and migration steps of that
 *            retirement — a replacement is not done until it is proven)
 *   feature  net-new end-user capability
 *
 * Two things are checked, and they fail for different reasons:
 *
 *   1. COVERAGE (hard failure). An active tasklist with no `category`, or one
 *      carrying a spelling outside the vocabulary, fails. A tasklist authored
 *      without a category would otherwise silently land outside the ordering
 *      rule, which is the one way this guard can be wrong without saying so.
 *      `completed/` records are NOT required to carry one: backfilling 245
 *      historical records buys nothing, and the ordering question is only ever
 *      asked about work that has not run yet.
 *
 *   2. THE FEATURE GATE (reported, not enforced). While any unparked
 *      fix/unblock/replace tasklist is outstanding, feature work is gated —
 *      the script says so and names how much is left, but exits 0. Refusing
 *      the build over it would be wrong: a category is a statement about a
 *      tasklist, and the decision to run one anyway is the operator's.
 *      `--strict` makes the gate a failure for a CI job that wants it.
 *
 * PARKED tasklists are excluded from the gate's arithmetic but still need a
 * category — parked is a statement about scheduling, not about kind, and a
 * tasklist is routinely unparked without being re-read.
 *
 * Usage: node scripts/check-tasklist-categories.mjs [--strict] [--json]
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const CATEGORIES = ['fix', 'unblock', 'replace', 'feature'];
const ORDERED_BEFORE_FEATURES = ['fix', 'unblock', 'replace'];
const DIR = 'tasks/chief';

const strict = process.argv.includes('--strict');
const asJson = process.argv.includes('--json');

const rows = [];
const errors = [];

for (const entry of readdirSync(DIR).sort()) {
  if (!entry.endsWith('.json')) continue;
  const stem = entry.slice(0, -5);
  let doc;
  try {
    doc = JSON.parse(readFileSync(join(DIR, entry), 'utf8'));
  } catch (err) {
    errors.push(`${stem}: unreadable (${err.message})`);
    continue;
  }
  const category = doc.category;
  if (category === undefined) {
    errors.push(`${stem}: no "category" — add one of ${CATEGORIES.join(' | ')}`);
    continue;
  }
  if (!CATEGORIES.includes(category)) {
    errors.push(`${stem}: category "${category}" is not one of ${CATEGORIES.join(' | ')}`);
    continue;
  }
  rows.push({ stem, category, parked: Boolean(doc.parked) });
}

const live = rows.filter((r) => !r.parked);
const count = (cat, set) => set.filter((r) => r.category === cat).length;
const outstanding = ORDERED_BEFORE_FEATURES.reduce((n, c) => n + count(c, live), 0);

if (asJson) {
  const byCategory = Object.fromEntries(
    CATEGORIES.map((c) => [c, { live: count(c, live), parked: count(c, rows.filter((r) => r.parked)) }]),
  );
  console.log(JSON.stringify({ total: rows.length, byCategory, outstanding, errors }, null, 2));
} else {
  for (const c of CATEGORIES) {
    const l = count(c, live);
    const p = count(c, rows.filter((r) => r.parked));
    console.log(`  ${c.padEnd(8)} ${String(l).padStart(3)} active${p ? `  (+${p} parked)` : ''}`);
  }
  console.log();
  if (outstanding > 0) {
    const detail = ORDERED_BEFORE_FEATURES.map((c) => `${count(c, live)} ${c}`).join(' + ');
    console.log(`  feature work is GATED — ${outstanding} outstanding (${detail})`);
  } else {
    console.log('  feature work is OPEN — no fix/unblock/replace tasklists remain unparked');
  }
}

if (errors.length) {
  console.error(`\ntasklist-categories: ${errors.length} error(s)`);
  for (const e of errors) console.error(`  ${e}`);
  process.exit(1);
}
if (strict && outstanding > 0) {
  console.error(`\ntasklist-categories: --strict and ${outstanding} fix/unblock/replace tasklists are outstanding`);
  process.exit(1);
}
if (!asJson) console.log(`\ntasklist-categories: OK — ${rows.length} tasklists categorized`);
