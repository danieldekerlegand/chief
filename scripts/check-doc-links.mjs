#!/usr/bin/env node
/**
 * Documentation link gate — every local doc reference must resolve.
 *
 * Measured 2026-08-14 across 16 repos: 243 distinct doc paths were cited by tracked files and
 * did not exist. Separately, a docs restructure moved ~900 files and orphaned 4,093 references
 * in one commit — code comments, tests, CI workflows, .chief config and prose — and that was
 * caught by eye rather than by a gate. This is the gate.
 *
 * LOCAL ONLY, and that is deliberate. External URL checking (lychee et al) fails for network
 * reasons, and a gate that fails for reasons unrelated to the change is a gate that gets
 * disabled — which costs more than the rot it was meant to catch. Run an external sweep on a
 * cadence instead; block merges only on references this repo can actually resolve.
 *
 * RATCHET, not a wall. 243 pre-existing dead references mean a hard gate blocks every merge on
 * day one. `--ratchet --base <ref>` compares HEAD against the base and fails only on a
 * REGRESSION, mirroring `engine/quality.sh ratchet`. Rot cannot grow; existing rot is retired
 * deliberately rather than in one forced sweep.
 *
 * Two reference forms are checked, because both broke in practice:
 *   - markdown links — [text](path), resolved relative to the citing FILE
 *   - bare doc paths in prose, code comments, CI and config — docs/..., resolved from REPO ROOT
 *
 * Usage: node scripts/check-doc-links.mjs [--json] [--list] [--ratchet --base <ref>]
 */
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname, normalize } from 'node:path';

const args = process.argv.slice(2);
const asJson = args.includes('--json');
const list = args.includes('--list');
const ratchet = args.includes('--ratchet');
const base = args[args.indexOf('--base') + 1];

const SKIP_DIR = ['/.git/', '/node_modules/', '/target/', '/.venv/', '/dist/', '/build/', '/.chief/state/'];
const SKIP_EXT = ['.png', '.jpg', '.jpeg', '.gif', '.pdf', '.svg', '.ico', '.woff', '.woff2', '.gz', '.zip', '.lock'];
const MD_LINK = /\[[^\]]*\]\(([^)\s]+)\)/g;
const BARE_DOC = /(?<![\w/.\-`])(docs\/[A-Za-z0-9_.\/-]+\.md)/g;
const NUL = String.fromCharCode(0);

// Paths listed in docs/.linkignore (prefix match, # comments) are not checked. The case that
// forced it: cuneiform GENERATES argos and studio-os, so its render templates and golden
// fixtures contain paths that are correct IN THE EXPORT — `docs/decisions/0002-clean-room-posture.md`
// resolves in argos, not here. Those are not rot, and "fixing" them would corrupt what the
// generator emits.
const EXCEPT_DIRS = (() => {
  try {
    return readFileSync('docs/.structure-exceptions', 'utf8').split('\n')
      .map((l) => l.split('#')[0].trim().replace(/\/$/, '')).filter(Boolean)
      .map((d) => `docs/${d}/`);
  } catch { return []; }
})();

const IGNORE = (() => {
  try {
    return readFileSync('docs/.linkignore', 'utf8').split('\n')
      .map((l) => l.split('#')[0].trim()).filter(Boolean);
  } catch { return []; }
})();

const tracked = () =>
  execFileSync('git', ['ls-files'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    .split('\n').filter(Boolean);

function scan() {
  const broken = [];
  for (const rel of tracked()) {
    if (SKIP_DIR.some((s) => `/${rel}`.includes(s))) continue;
    // Archived documents are NOT gated as citers. An archived doc records a past state; its
    // links described the tree AS IT WAS. Repointing them at today's files would make the
    // document misrepresent what it documented — the same reason an ADR is superseded rather
    // than edited. The archive banner already tells the reader it is not current. Links INTO
    // archive/ from live docs are still checked: those are a live document's promise.
    if (rel.includes('docs/archive/')) continue;
    // Completed tasklists are history too. A merged tasklist records what was true when it ran,
    // and its references were valid then; rewriting them would falsify the work record. This is
    // the same reason the restructure deliberately left completed/ untouched.
    if (rel.includes('tasks/chief/completed/')) continue;
    if (IGNORE.some((g) => rel.startsWith(g))) continue;
    if (EXCEPT_DIRS.some((d) => rel.startsWith(d))) continue;
    if (SKIP_EXT.some((e) => rel.toLowerCase().endsWith(e))) continue;
    let body;
    try { body = readFileSync(rel, 'utf8'); } catch { continue; }
    if (body.includes(NUL)) continue;

    if (rel.endsWith('.md')) {
      for (const m of body.matchAll(MD_LINK)) {
        const raw = m[1];
        if (/^([a-z]+:|#|\/\/)/i.test(raw)) continue;
        const decoded = (() => { try { return decodeURIComponent(raw.split('#')[0]); }
                                 catch { return raw.split('#')[0]; } })();
        const p = normalize(join(dirname(rel), decoded));
        if (!p || p.startsWith('..')) continue;
        if (!existsSync(p)) broken.push({ from: rel, to: raw, kind: 'link' });
      }
    }
    // Structured cross-repo references are NOT rot. insimul's contract files carry objects like
    // { "repo": "chief", "path": `docs/events.md` } — the path is correct RELATIVE TO THAT REPO,
    // and flagging it would make the gate noisy about things that are right. A noisy gate gets
    // switched off, so the parser skips any docs/ path inside an object that names another repo.
    const foreign = new Set();
    if (rel.endsWith('.json')) {
      const own = (() => { try { return execFileSync('git', ['rev-parse', '--show-toplevel'],
        { encoding: 'utf8' }).trim().split('/').pop(); } catch { return ''; } })();
      const walk = (node, inForeign) => {
        if (Array.isArray(node)) return node.forEach((n) => walk(n, inForeign));
        if (!node || typeof node !== 'object') return;
        const named = node.repo || node.owner;
        const isForeign = inForeign || (typeof named === 'string' && named && named !== own);
        for (const v of Object.values(node)) {
          if (typeof v === 'string' && isForeign && v.startsWith('docs/')) foreign.add(v);
          else walk(v, isForeign);
        }
      };
      try { walk(JSON.parse(body), false); } catch { /* not parseable — fall through */ }
    }
    for (const m of body.matchAll(BARE_DOC)) {
      if (foreign.has(m[1])) continue;
      if (!existsSync(m[1])) broken.push({ from: rel, to: m[1], kind: 'path' });
    }
  }
  return broken;
}

const broken = scan();
const distinct = new Set(broken.map((b) => b.to));

if (ratchet) {
  if (!base) { console.error('--ratchet requires --base <ref>'); process.exit(2); }
  let before = null;
  try {
    const script = new URL(import.meta.url).pathname;
    const out = execFileSync('bash', ['-c',
      `set -e; d=$(mktemp -d); git worktree add -q --detach "$d" ${base} >/dev/null 2>&1; ` +
      `(cd "$d" && node ${script} --json 2>/dev/null); ` +
      `git worktree remove --force "$d" >/dev/null 2>&1`],
      { encoding: 'utf8' });
    before = JSON.parse(out).distinct;
  } catch { before = null; }
  const now = distinct.size;
  if (before === null || Number.isNaN(before)) {
    console.log(`doc-links: ${now} dead reference(s); base unavailable — reporting only`);
    process.exit(0);
  }
  console.log(`doc-links: ${now} dead vs ${before} on ${base}`);
  if (now > before) {
    console.error(`\ndoc-links: REGRESSION — ${now - before} new dead reference(s)`);
    for (const b of broken.slice(0, 20)) console.error(`  ${b.from} -> ${b.to}`);
    process.exit(1);
  }
  if (now < before) console.log(`  retired ${before - now}`);
  process.exit(0);
}

if (asJson) {
  console.log(JSON.stringify({ total: broken.length, distinct: distinct.size }, null, 2));
} else {
  console.log(`  dead references   ${broken.length}  (${distinct.size} distinct targets)`);
  if (list) {
    const by = new Map();
    for (const b of broken) by.set(b.to, [...(by.get(b.to) || []), b.from]);
    for (const [to, froms] of [...by].sort((a, b) => b[1].length - a[1].length)) {
      console.log(`\n  ${to}  (${froms.length})`);
      for (const f of froms.slice(0, 6)) console.log(`      ${f}`);
    }
  }
}
