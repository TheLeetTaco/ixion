# Research Workflow

Canonical locate → consolidate → analyze flow used by every research caller (`plan-creation`, `research`, `brainstorm`). Every caller runs all three phases. Caller-specific synthesis (how analyzer outputs map to the caller's downstream artifact) lives in each caller's own reference file.

All locators and analyzers run in **documentarian mode** — document what exists, do not suggest changes. Substitute `<topic>` with the caller's input (feature description, research question, brainstorm idea).

---

## Phase 1: Locate (parallel)

Run the locators in a single message with parallel Task calls. Wait for all to complete. Locators have no Read tool — pass search context inline. Return paths/references only — no file contents.

**Web-leg skip:** if the topic names no external library, framework, or API — purely internal code, conventions, or refactoring — skip `locator-web` (and later `analyzer-web`). Dispatch three locators, not four. The web pair costs the most wall-clock and a sonnet dispatch; internal topics get nothing back from it.

**Warm-start fast path:** if the caller already holds ≥5 concrete inputs for a category (e.g. Phase-0 knowledge checks surfaced file paths, or the user named them), skip that category's locator and dispatch its analyzer directly — in the same parallel message as the remaining locators. Cold categories still run locate → consolidate → analyze.

### locator-codebase

```
Task locator-codebase: "
Find files related to: <topic>
Return paths only — no file contents.
Categorize by: implementation, tests, config, types, docs.
Max 30 paths.
"
```

### locator-patterns

```
Task locator-patterns: "
Find patterns related to: <topic>
Looking for: naming conventions, architectural patterns, testing patterns.
Return file:line references only.
Group by pattern type.
Max 30 locations.
"
```

### locator-docs

```
Task locator-docs: "
Find documentation about: <topic>
Search: README, CLAUDE.md, docs/, inline comments.
Return paths only.
Max 20 paths.
"
```

### locator-web

```
Task locator-web: "
Find documentation/articles about: <topic>
Return URLs with descriptions only — do not fetch.
Categorize: official docs, tutorials, community.
Max 20 URLs per category.
"
```

---

## Phase 2: Consolidate

Combine locator outputs into ranked top-N inputs for the analyzers.

1. **Deduplicate** — same file/URL from multiple locators = 1 entry.
2. **Rank by relevance**:
   - Mentioned by multiple locators = higher relevance
   - Closer path/URL match to topic = higher relevance
   - Implementation files > test files (usually)
3. **Select for analysis**:
   - Top 15 file paths → analyzer-codebase
   - Top 10 pattern locations → analyzer-patterns
   - Top 5 documentation paths → analyzer-docs
   - Top 10 URLs → analyzer-web

**Skip condition:** if total findings < 10, the topic is too narrow to benefit from deep analysis. Skip Phase 3 and treat the consolidated locator results as the final research output.

---

## Phase 3: Analyze (parallel)

Run the analyzers in parallel where inputs are independent (all four, minus any category already analyzed via the warm-start fast path and minus the web pair if skipped). Each analyzer receives its top-N inputs from Phase 2. All analyzers operate in documentarian mode — flags below are observations (not recommendations), so they remain documentarian-compliant.

### analyzer-codebase

```
Task analyzer-codebase: "
Analyze these files (from locator results):
- path/to/file1.rs
- path/to/file2.rs
[... up to 15 files]

Topic: <topic>

Document:
1. What exists, how it works, how components interact
2. File structure and naming conventions
3. Architectural patterns and testing patterns
4. Overlap with the topic — code that already covers it, in part or in whole
5. Integration surface — consumers, callers, tests that touch these files

Flag (only when present in the files; do not invent):
- EXISTING_SOLUTION — code that already covers the topic
- PATTERN_CONFLICT — established conventions the topic would deviate from
- DRY_VIOLATION — duplicated logic across the analyzed files
- INTEGRATION_RISK — consumers or tests that changes would impact
- OPEN_QUESTION — ambiguities or multiple plausible interpretations

Return: file paths with line numbers (e.g., src/services/auth.rs:42).
Documentarian mode — document what exists, do not suggest changes.
"
```

### analyzer-patterns

```
Task analyzer-patterns: "
Analyze these patterns (from locator results):
- pattern at file.rs:42
- pattern at other.rs:89
[... up to 10 locations]

Topic: <topic>

Extract code examples with context. Name each pattern so a reader can match it.
Flag PATTERN_CONFLICT if the patterns disagree across locations.
Documentarian mode — document what exists, do not suggest alternatives.
"
```

### analyzer-docs

```
Task analyzer-docs: "
Analyze this documentation (from locator results):
- docs/feature.md
- README.md section
[... up to 5 docs]

Topic: <topic>

Extract: decisions, constraints, setup instructions, warnings.
Flag OPEN_QUESTION if docs disagree or leave a decision pending.
Filter aggressively — skip tangential mentions.
"
```

### analyzer-web

```
Task analyzer-web: "
Fetch and analyze these URLs (from locator-web):
- https://docs.example.com/...
- https://github.com/...
[... up to 10 URLs]

Topic: <topic>

Extract: code examples, configuration, version constraints, warnings.
Flag CLAIM_INVALID if the URL contradicts an assumption stated in the topic, or
VERSION_ISSUE if a referenced version is deprecated or has breaking changes.
"
```

---

## What callers do next

The four analyzer outputs (plus locator results that didn't promote into Phase 3) are the canonical research data. Each caller's own reference file specifies how to map those outputs into the caller's downstream artifact (`spec.context`, the persisted research doc, brainstorm's approach options, etc.). The dispatch shape, parallelism, and documentarian discipline above are universal.
