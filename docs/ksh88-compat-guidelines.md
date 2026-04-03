# ksh88 Compatibility Guidelines for MQ Metrics Scripts

## Overview

The `mq-metrics.ksh` script targets **AIX systems running ksh88** but is developed and tested in container environments running **ksh93** (or mksh). Several ksh93-specific constructs silently break or produce unexpected results on ksh88. This document catalogues each incompatibility and provides portable alternatives.

---

## 1. Array Syntax

### Problem

ksh93 arrays (`typeset -a`, `set -A`, `${#arr[@]}`, `"${arr[@]}"`) are partially supported in ksh88 but behave inconsistently — particularly `${#arr[@]}` for counting elements and `"${arr[@]}"` for safe iteration.

### Broken (ksh93-only)

```ksh
typeset -a qmgrs
typeset IFS=','
set -A qmgrs $QMGR_LIST

if [[ ${#qmgrs[@]} -eq 0 ]]; then
    log_error "No running queue managers found"
    exit 1
fi

for qm in "${qmgrs[@]}"; do
    collect_qmgr "$qm"
done
```

### Portable Fix

Use plain string variables with word-splitting:

```ksh
# Convert comma-separated list to space-separated
qmgrs=$(echo "$QMGR_LIST" | tr ',' ' ')

if [[ -z "$qmgrs" ]]; then
    log_error "No running queue managers found"
    exit 1
fi

# Unquoted expansion triggers word-splitting (intentional)
for qm in $qmgrs; do
    collect_qmgr "$qm"
done
```

### Rule

**Avoid ksh arrays entirely.** Use space-delimited strings and unquoted expansion for iteration. This is safe as long as values do not contain spaces (queue manager names never do).

---

## 2. Parameter Expansion — Unescaped Parentheses in Patterns

### Problem

In `${var#pattern}` and `${var%%pattern}` expansions, ksh88 may interpret an unescaped `(` as the start of a pattern group, causing syntax errors or incorrect matches. ksh93 is more lenient.

### Broken (ksh93-only)

```ksh
queue="${line#*QUEUE(}"
queue="${queue%%)*}"

curdepth="${line#*CURDEPTH(}"
curdepth="${curdepth%%)*}"
```

### Portable Fix

Escape parentheses with `\(` and `\)` in the pattern:

```ksh
queue="${line##*QUEUE\(}"
queue="${queue%%\)*}"

curdepth="${line##*CURDEPTH\(}"
curdepth="${curdepth%%\)*}"
```

### Rule

**Always escape `(` and `)` in parameter expansion patterns.** These characters can be pattern metacharacters in ksh88.

### Note on `#` vs `##`

- `${var#pattern}` — removes the **shortest** matching prefix.
- `${var##pattern}` — removes the **longest** matching prefix.

For `runmqsc` output where each keyword (e.g. `QUEUE(`, `CURDEPTH(`) appears only once per line, both work identically. Prefer `##` for defensive consistency — if a line ever contained the keyword more than once, `##` would still extract the last occurrence.

---

## 3. `typeset` Scoping Inside Functions

### Problem

In ksh88, `typeset` inside a function creates a **local** variable only when the function is defined with the `function name { }` syntax. With the POSIX `name() { }` syntax (used throughout the script), `typeset` may not provide local scoping and can cause confusing interactions with global variables.

### Broken (unreliable on ksh88)

```ksh
collect_qmgr() {
    typeset qmgr="$1"
    typeset timestamp
    typeset tmpfile="/tmp/mq-metrics.$$.${qmgr}"
    typeset queue="" curdepth="" maxdepth=""
    ...
}
```

### Portable Fix

Drop `typeset` and use plain assignments with per-function prefixed variable names to avoid collisions:

```ksh
collect_qmgr() {
    _cq_qmgr="$1"
    _cq_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    _cq_tmpdir="/tmp/mq-metrics-merge.$$.$_cq_qmgr"
    _cq_queue="" ; _cq_curdepth="" ; _cq_maxdepth=""
    ...
}
```

### Rule

**Do not rely on `typeset` for local scoping in `name()` functions.** Use global variables with a per-function prefix convention (e.g. `_cq_` for `collect_qmgr`, `_pl_` for `parse_qlocal`). This prevents collisions between functions since all variables are effectively global.

---

## 4. Pipeline Subshell Variable Scoping

### Problem

In ksh88, each segment of a pipeline runs in a **subshell**. Variables set inside a `while read` loop that is part of a pipeline are lost when the pipeline exits. ksh93 runs the last pipeline segment in the current shell, so variables survive.

### Broken (ksh93-only)

```ksh
# BROKEN on ksh88 — $result is always empty after the pipeline
dspmq | while read -r line; do
    result="$result $line"
done
echo "$result"   # empty!
```

### Portable Fix

Redirect from a temp file instead of piping:

```ksh
discover_qmgrs() {
    _dq_tmp="/tmp/mq-metrics-dspmq.$$"
    dspmq >"$_dq_tmp" 2>/dev/null
    _dq_list=
    while read -r line; do
        _dq_status=$(extract_val STATUS "$line")
        if [[ "$_dq_status" = "Running" ]]; then
            _dq_qm=$(extract_val QMNAME "$line")
            _dq_list="${_dq_list}${_dq_qm} "
        fi
    done < "$_dq_tmp"
    rm -f "$_dq_tmp"
    print "$_dq_list"
}
```

### Rule

**Never set variables inside a piped `while read` loop if you need them after the loop.** Redirect from a file or use a temp file instead of a pipe.

---

## 5. `IFS=` in `while read`

### Problem

`while IFS= read -r line` is POSIX-compliant but some ksh88 versions handle inline `IFS=` assignment inconsistently.

### Portable Fix

If preserving leading/trailing whitespace is not critical (it isn't for `runmqsc` output parsing), simply drop the `IFS=`:

```ksh
while read -r line; do
    ...
done < "$tmpfile"
```

### Rule

**Drop `IFS=` from `while read` unless whitespace preservation is essential.** For structured output parsing (like `runmqsc`), trimmed lines are fine.

---

## 6. Logging — `$*` vs `$@`

### Problem

`log_info()` and `log_error()` use `$*` (joins all arguments with the first character of IFS). If IFS has been modified earlier (e.g., set to `,`), log messages may be corrupted.

### Portable Fix

Use `$@` (preserves original argument separation):

```ksh
log_info()  { print -u2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ') INFO  $@"; }
log_error() { print -u2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR $@"; }
```

### Rule

**Prefer `$@` over `$*` in functions**, especially if IFS may be modified elsewhere in the script.

---

## 7. Array Lookup Tables

### Problem

Functions like `elapsed_seconds()` and `get_epoch()` need a lookup table for cumulative days per month. ksh93 arrays (`set -A`) work but are not portable to ksh88.

### Broken (ksh93-only)

```ksh
set -A mdays 0 31 59 90 120 151 181 212 243 273 304 334
typeset m=$((10#$month))
typeset month_days=${mdays[$((m - 1))]}
```

### Portable Fix

Use positional parameters (`set --`) and `eval` for indexed access:

```ksh
set -- 0 31 59 90 120 151 181 212 243 273 304 334
_es_m=$((10#$_es_month))
eval _es_month_days=\${$_es_m}
```

The `eval` is safe here because `_es_m` is always a number 1-12 derived from timestamp parsing.

### Rule

**Use `set --` and `eval` for lookup tables instead of arrays.** This is portable across all ksh variants and POSIX shells.

---

## 8. Variable-Prefix Convention

### Problem

Since `typeset` does not create locals in `name()` functions on ksh88, all variables are global. Functions can accidentally overwrite each other's variables, especially when calling helpers like `extract_val()` from within `parse_qlocal()`.

### Convention

Each function uses a unique 2-4 character prefix for all its variables:

| Function | Prefix | Example |
|---|---|---|
| `extract_val` | `_ev_` | `_ev_key`, `_ev_src`, `_ev_tmp` |
| `discover_qmgrs` | `_dq_` | `_dq_list`, `_dq_tmp` |
| `parse_qlocal` | `_pl_` | `_pl_queue`, `_pl_curdepth` |
| `parse_qstatus` | `_ps_` | `_ps_queue`, `_ps_lputdate` |
| `write_qstatus` | `_ws_` | `_ws_dir`, `_ws_q` |
| `mq_to_iso` | `_mi_` | `_mi_d`, `_mi_hh` |
| `elapsed_seconds` | `_es_` | `_es_iso`, `_es_year` |
| `get_epoch` | `_ge_` | `_ge_epoch`, `_ge_year` |
| `collect_qmgr` | `_cq_` | `_cq_qmgr`, `_cq_queue` |
| `send_bulk` | `_sb_` | `_sb_bulkfile` |

### Rule

**Always use the per-function prefix for all variables** in `name()` functions. This prevents collisions without relying on `typeset` scoping.

---

## Quick-Reference Checklist

Use this checklist when writing or reviewing ksh scripts that must run on AIX ksh88:

| # | Check | Rationale |
|---|-------|-----------|
| 1 | No ksh arrays (`typeset -a`, `set -A`, `${arr[@]}`) | Use space-delimited strings instead |
| 2 | Parentheses escaped in `${var#pattern}` expansions | `\(` and `\)` to avoid pattern group interpretation |
| 3 | No `typeset` in `name()` functions for local scoping | Use per-function variable prefix convention |
| 4 | No variable mutation inside piped `while read` | Use temp file + redirect instead of pipe |
| 5 | No `IFS=` inline with `while read` | Drop it or set IFS on a separate line |
| 6 | Use `$@` instead of `$*` in functions | Robust against IFS changes |
| 7 | No `set -A` for lookup tables | Use `set --` + `eval` |
| 8 | Per-function variable prefix | Prevents global variable collisions |
| 9 | Test on mksh (ksh88 proxy) or actual AIX ksh88 | Container shells (ksh93) mask these issues |
