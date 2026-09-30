#!/usr/bin/env node
// repo-advisories.mjs <chain-root> <lockfile-dir>... — read the production
// packages of each npm lockfile against the security advisories their own
// GitHub repositories publish.
//
// Why a second source at all: `npm audit`, `osv-scanner` and Dependabot alerts
// all read the global advisory database. A repository advisory reaches that
// database only once GitHub reviews it, and until then all three are blind to it
// at once. Measured 2026-09-25: fast-uri 3.1.7 sat in three of the chain's four
// lockfiles inside GHSA-hrr3-gc8f-f4qj for ten days; the global endpoint
// answered 404, OSV answered nothing, and two parity rounds reported 0.
//
// What this reads: every non-dev package in each lockfile, mapped to its GitHub
// repository through the `repository` field of its installed package.json (so a
// tree without node_modules maps nothing, and says so). Each repository is asked
// once, and each npm advisory's vulnerable ranges are compared with the locked
// version.
//
// The token comes from GH_TOKEN (lib.sh passes `gh auth token`); ~100
// repositories are past the unauthenticated rate limit, so without one the step
// reports itself skipped rather than half-answered.
//
// Output: one line per lockfile (clean / findings / skipped) plus one detail
// line per finding, in the shape report_advisories prints. Exit is ALWAYS 0: an
// advisory is answered by a human, not by an exit code (see lib.sh).

import { readFileSync } from "node:fs";
import path from "node:path";

const [root, ...dirs] = process.argv.slice(2);
const token = process.env.GH_TOKEN;

const line = (verdict, subject) => console.log(`  ${verdict.padEnd(11)} ${subject}`);
const detail = (text) => console.log(`              ${text}`);

if (!token) {
  line("skipped", "no GitHub token — ~100 repositories exceed the anonymous rate limit");
  process.exit(0);
}

// "1.2.3" -> [1,2,3]; prerelease tags are dropped, which errs toward matching.
const parse = (v) => v.replace(/^v/, "").split(/[-+]/)[0].split(".").map((n) => Number(n) || 0);
function compare(a, b) {
  const x = parse(a);
  const y = parse(b);
  for (let i = 0; i < 3; i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
  return 0;
}
// GitHub's range syntax: comparators joined by ", " -- ">= 3.0.0, < 3.1.8", "= 3.1.6".
function inRange(version, range) {
  return range.split(",").every((clause) => {
    const m = /^\s*(>=|<=|>|<|=)?\s*(\S+)\s*$/.exec(clause);
    if (!m) return false;
    const c = compare(version, m[2]);
    switch (m[1] ?? "=") {
      case ">=": return c >= 0;
      case "<=": return c <= 0;
      case ">": return c > 0;
      case "<": return c < 0;
      default: return c === 0;
    }
  });
}

// Repository advisories often give an open-ended range (">= 0.79.0", "> 1.1.0")
// and name the fix only in patched_versions, so a range match alone reports every
// later release as vulnerable. A version at or past a patched release on the same
// major line is fixed; patched_versions may list one fix per major, comma-joined.
function isPatched(version, patched) {
  if (!patched) return false;
  const major = parse(version)[0];
  return patched
    .split(",")
    .map((p) => p.trim())
    .filter(Boolean)
    .some((p) => parse(p)[0] === major && compare(version, p) >= 0);
}

function repositoryOf(dir, key) {
  let repo;
  try {
    repo = JSON.parse(readFileSync(path.join(dir, key, "package.json"), "utf8")).repository;
  } catch {
    return undefined;
  }
  const url = typeof repo === "string" ? repo : repo?.url;
  if (!url) return undefined;
  const m =
    /github\.com[/:]([\w.-]+)\/([\w.-]+?)(?:\.git)?(?:[/#].*)?$/.exec(url) ??
    /^(?:github:)?([\w.-]+)\/([\w.-]+)$/.exec(url);
  return m ? `${m[1]}/${m[2]}` : undefined;
}

const cache = new Map();
function advisoriesOf(repo) {
  if (!cache.has(repo)) {
    const url = `https://api.github.com/repos/${repo}/security-advisories?state=published&per_page=100`;
    cache.set(
      repo,
      fetch(url, {
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "User-Agent": "zed-patches-repo-advisories",
        },
        signal: AbortSignal.timeout(20_000),
      })
        .then((res) => (res.ok ? res.json() : null))
        // A renamed, private or archived repository is not a finding; it is a
        // question this source cannot answer, and it is counted as such below.
        .catch(() => null),
    );
  }
  return cache.get(repo);
}

for (const rel of dirs) {
  const dir = path.join(root, rel);
  let lock;
  try {
    lock = JSON.parse(readFileSync(path.join(dir, "package-lock.json"), "utf8"));
  } catch {
    line("skipped", `${rel}/package-lock.json — not there`);
    continue;
  }

  const packages = [];
  let unmapped = 0;
  for (const [key, entry] of Object.entries(lock.packages ?? {})) {
    if (!key || entry.dev || entry.link || !entry.version) continue;
    const name = key.replace(/^.*node_modules\//, "");
    const repo = repositoryOf(dir, key);
    if (repo) packages.push({ name, version: entry.version, repo });
    else unmapped++;
  }
  if (packages.length === 0) {
    line("skipped", `${rel} — no installed node_modules to map packages to repositories`);
    continue;
  }

  const findings = [];
  let unanswered = 0;
  const answers = await Promise.all(packages.map((p) => advisoriesOf(p.repo)));
  packages.forEach((pkg, i) => {
    const advisories = answers[i];
    if (!Array.isArray(advisories)) {
      unanswered++;
      return;
    }
    for (const advisory of advisories) {
      for (const vuln of advisory.vulnerabilities ?? []) {
        if (vuln.package?.ecosystem !== "npm" || vuln.package?.name !== pkg.name) continue;
        if (!vuln.vulnerable_version_range) continue;
        // A bare version with a fix named elsewhere is a malformed range, not an
        // exact match: @agentclientprotocol/sdk's GHSA-6q4g-4xp9-ch96 publishes
        // "0.27.0" with patched_versions "1.5.1", and reading it as "= 0.27.0"
        // hid 1.5.0 on 2026-09-29. Read it as "from there up to the newest fix":
        // open-ended alone would also flag 1.5.0 under GHSA-p29f-jffj-96g8, whose
        // bare "0.27.0" is fixed in 0.27.1, a line isPatched does not compare.
        const newestFix = (vuln.patched_versions ?? "")
          .split(",")
          .map((p) => p.trim())
          .filter(Boolean)
          .sort(compare)
          .at(-1);
        const range =
          newestFix && /^\s*[\d.]+\s*$/.test(vuln.vulnerable_version_range)
            ? `>= ${vuln.vulnerable_version_range.trim()}, < ${newestFix}`
            : vuln.vulnerable_version_range;
        if (!inRange(pkg.version, range)) continue;
        if (isPatched(pkg.version, vuln.patched_versions)) continue;
        findings.push(
          `${pkg.name} ${pkg.version} — ${advisory.ghsa_id} (${advisory.severity}), ` +
            `fixed in ${vuln.patched_versions || "?"}: ${advisory.summary}`,
        );
      }
    }
  });

  const repos = new Set(packages.map((p) => p.repo)).size;
  const scope =
    `${packages.length} packages, ${repos} repositories` +
    (unmapped ? `, ${unmapped} unmapped` : "") +
    (unanswered ? `, ${unanswered} unanswered` : "");
  if (findings.length === 0) {
    line("clean", `${rel} (${scope})`);
  } else {
    line("findings", `${rel} (${scope})`);
    for (const f of [...new Set(findings)]) detail(f);
  }
}
