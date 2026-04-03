# runmqsc Output Parsing -- Pitfalls and Solutions

Findings from testing `runmqsc` output parsing on IBM MQ 9.3.0.25 (Linux container). These issues apply to all platforms including AIX.

---

## Output Layout

`runmqsc` formats DISPLAY command output in a **two-column layout**:

```
AMQ8450I: Display queue status details.
   QUEUE(APP.ORDERS.IN)                    TYPE(QUEUE)
   CURDEPTH(17)                            CURFSIZE(1)
   CURMAXFS(2088960)                       IPPROCS(0)
   LGETDATE( )                             LGETTIME( )
   LPUTDATE(2026-04-03)                    LPUTTIME(15.24.19)
```

Each attribute is in `KEY(VALUE)` format. Two attributes per line, separated by whitespace. The exact column positions are not fixed -- they depend on the length of attribute values.

---

## Line Wrapping with Long Queue Names

When a queue name exceeds the first column width, `QUEUE(name)` takes the **entire line** and all subsequent attributes shift to the next lines:

```
   QUEUE(SYSTEM.ADMIN.TRACE.ACTIVITY.QUEUE)
   TYPE(QUEUE)                             CURDEPTH(0)
   CURFSIZE(1)                             CURMAXFS(2088960)
   IPPROCS(0)                              LGETDATE( )
```

Compare with a shorter name where everything fits:

```
   QUEUE(APP.ORDERS.IN)                    TYPE(QUEUE)
   CURDEPTH(17)                            CURFSIZE(1)
```

**Impact on parsing**: Attributes are NOT on predictable line positions. A parser must scan for `KEY(VALUE)` patterns on **any** line between two `QUEUE(` markers, not assume fixed positions.

This affects both `DISPLAY QLOCAL` and `DISPLAY QSTATUS` identically.

---

## ksh case/parenthesis Parsing Bug

**This is the most critical finding.**

The common idiom for extracting `KEY(VALUE)` in ksh is:

```ksh
val="${line#*KEY(}"     # strip prefix up to KEY(
val="${val%%)*}"        # strip suffix from first )
```

This works fine in standalone code, but **breaks inside a `case` block**:

```ksh
# THIS FAILS with "syntax error: `}' unexpected"
while IFS= read -r line; do
    case "$line" in
        *QUEUE\(*)
            queue="${line#*QUEUE(}"       # <-- ( confuses ksh
            queue="${queue%%)*}"          # <-- ) confuses ksh
            ;;
    esac
done < "$tmpfile"
```

**Root cause**: ksh interprets `(` and `)` inside a `case` body as case pattern syntax, not as literal characters in parameter expansion. The `${var%%)*}` pattern's `)` is parsed as the case pattern terminator, and `${var#*KEY(}` has an unmatched `(`.

**Affected versions**: Confirmed on ksh93u+m/1.0.8. Likely affects all ksh88 and ksh93 variants including AIX's `/usr/bin/ksh`.

### Solution 1: Escape the parentheses

```ksh
queue="${line#*QUEUE\(}"
queue="${queue%%\)*}"
```

### Solution 2: Use a helper function (recommended)

Extract the parsing into a separate function outside any `case` block. The function uses escaped parentheses and prefixed globals for ksh88 compatibility (see `docs/ksh88-compat-guidelines.md`):

```ksh
extract_val() {
    _ev_key="$1" ; _ev_src="$2"
    case "$_ev_src" in
        *${_ev_key}\(*)
            _ev_tmp="${_ev_src#*${_ev_key}\(}"
            print "${_ev_tmp%%\)*}"
            ;;
    esac
}

# Usage:
queue=$(extract_val QUEUE "$line")
curdepth=$(extract_val CURDEPTH "$line")
```

The helper function isolates the pattern matching in a controlled context where the quoting works correctly. This is the approach used in `mq-metrics.ksh`.

---

## UNCOM Value Format

`UNCOM` returns a **string**, not a number:

```
UNCOM(NO)     -- no uncommitted changes
UNCOM(YES)    -- uncommitted puts or gets pending
```

It is NOT a count. There is no way to get the number of uncommitted messages via `DISPLAY QSTATUS`.

**Parsing**: Map to boolean in output, not numeric.

---

## QTIME Value Format

`QTIME` returns **two values** (short-term and long-term averages) in microseconds:

```
QTIME(12345, 67890)    -- populated: short-term=12345, long-term=67890
QTIME( , )             -- empty: no data available
```

**Parsing notes**:
- Split on comma
- Trim **all** leading/trailing spaces (there may be multiple)
- After trimming, empty string means no data
- Values are integers (microseconds)

---

## Timestamp Formats

### LPUTTIME / LGETTIME

Format: `HH.MM.SS` -- uses **dots**, not colons:

```
LPUTTIME(15.24.19)    -- 15:24:19
LGETTIME( )           -- empty (single space) when no data
```

### LPUTDATE / LGETDATE

Format: `YYYY-MM-DD`:

```
LPUTDATE(2026-04-03)  -- populated
LGETDATE( )           -- empty (single space) when no data
```

### Combining into ISO 8601

```
LPUTDATE(2026-04-03) + LPUTTIME(15.24.19) -> 2026-04-03T15:24:19Z
```

Replace dots with colons in the time component.

---

## MSGAGE Format

```
MSGAGE(462)    -- oldest message is 462 seconds old
MSGAGE(0)      -- queue is empty (when MONQ is on)
MSGAGE( )      -- no data (when MONQ is off)
```

When MONQ is enabled, `MSGAGE` is always numeric -- `0` for empty queues.
When MONQ is off, it is a single space.

---

## Empty Values and MONQ

When queue monitoring is disabled (`MONQ(OFF)`), the following attributes return a **single space** instead of a value:

- `LPUTDATE( )`, `LPUTTIME( )`
- `LGETDATE( )`, `LGETTIME( )`
- `MSGAGE( )`
- `QTIME( , )`

Attributes that work regardless of MONQ:

- `CURDEPTH`, `IPPROCS`, `OPPROCS`, `UNCOM`

**Best practice**: Always check for empty/space values before using timestamp and age fields. Omit them from the output document rather than emitting null or blank.

---

## Record Boundaries

Each queue's data begins with a `QUEUE(name)` line and continues until the next `QUEUE(` marker or end of output. An `AMQ8450I` informational line appears before each record but should not be relied upon for parsing -- use `QUEUE(` as the delimiter.

```
AMQ8450I: Display queue status details.
   QUEUE(APP.ORDERS.IN)                    TYPE(QUEUE)
   CURDEPTH(17)                            ...
AMQ8450I: Display queue status details.
   QUEUE(APP.ORDERS.OUT)                   TYPE(QUEUE)
   CURDEPTH(9)                             ...
```

---

## Platform Consistency

Tested on MQ 9.3.0.25 Linux container. Shell parsing validated on mksh (ksh88 proxy) via `tests/run-ksh88-tests.sh`. Based on IBM documentation and web research:

- **Output format** (two-column KEY(VALUE) layout) is consistent across all platforms
- **Timestamp format** (HH.MM.SS with dots) is consistent across all platforms
- **Line wrapping** behavior with long names is consistent
- **Interactive vs piped output** -- no difference in format when `runmqsc` output is redirected or piped
- The ksh case/parenthesis bug is a **shell** issue, not an MQ issue -- it applies wherever ksh is the interpreter
- The `extract_val()` helper and all ksh88 compatibility patterns are validated by the mksh test harness
