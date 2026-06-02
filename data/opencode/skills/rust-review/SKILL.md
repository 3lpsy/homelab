---
name: rust-review
description: Review Rust code for correctness, idiom, and consistency — not just lint. Covers error handling, ownership, API design, naming, async pitfalls, unsafe, and perf. Read-only — surfaces findings with file:line, does NOT auto-fix.
---
# rust-review

When the user asks to review Rust code, lint, or "check this". Read-only:
surface findings with `file:line`, grouped by severity, and propose fixes
inline — do NOT edit until the user confirms. Do NOT run `cargo fix
--clippy` (it rewrites code).

## Pass 1 — mechanical (fast, do first)

    cargo clippy --workspace --all-targets -- -D warnings
    cargo fmt --all -- --check

Clippy catches a huge amount; report every finding with `file:line`. But
clippy is the floor, not the review — a clippy-clean diff can still be
unidiomatic, inconsistent, or wrong. The manual passes below are the
actual review.

## Pass 2 — correctness (highest severity)

- **Error handling:** no `unwrap()` / `expect()` / `panic!` /
  `unreachable!` / array-index `[i]` on non-test, non-invariant paths.
  Flag each; the idiomatic fix is `?` with `.ok_or(...)` / `.ok_or_else`
  for `Option` and a real error type for `Result`. `expect` is OK only
  with a message that documents a genuine invariant.
- **Swallowed errors:** `let _ = fallible();`, `.ok()` that drops a
  `Result`, `if let Ok(x) = ... {}` with no `else`. Flag silent drops.
- **Integer/`as` casts:** `as` truncates silently. Flag `as` on values
  that can exceed the target (use `try_into()` + handle the error, or
  `u32::from` for widening). Flag `as` used to drop signedness.
- **`unsafe`:** every `unsafe` block needs a `// SAFETY:` comment that
  actually justifies the invariants. Flag any without one, and any whose
  comment doesn't hold.
- **Float/`PartialEq` foot-guns, `unwrap` on locks** (`.lock().unwrap()`
  hides poisoning — at least note it).
- **`.await` while holding a `std::sync` guard / `RefCell` borrow** —
  blocks the executor or panics. High-severity async correctness bug.

## Pass 3 — idiom

- **Iterators over index loops:** `for i in 0..v.len() { v[i] }` →
  `for x in &v` / `.iter().enumerate()`. Flag manual index walking,
  `while let` that should be a `for`, and `loop { ... break }` that's a
  plain iterator chain.
- **Combinators where they read better:** `match opt { Some(x) => f(x),
  None => default }` → `.map_or` / `.unwrap_or_else`; nested `match` on
  `Result` → `?`. Don't push this to the point of unreadable chains.
- **Borrowing over cloning:** flag `.clone()` / `.to_vec()` /
  `.to_string()` reached for to dodge the borrow checker. Ask whether a
  `&`/`&str`/`&[T]` or restructuring removes it.
- **Param types:** `&str` not `&String`, `&[T]` not `&Vec<T>`,
  `impl AsRef<Path>` for path inputs, `impl Into<String>` when the fn
  takes ownership. Flag over-restrictive signatures.
- **Construction:** `From`/`TryFrom` not ad-hoc `to_x()` converters;
  `Default` where it fits; builder for many-optional-field structs.
- **String building:** `format!` in a hot loop → `write!` into a reused
  buffer; repeated `push_str` → `concat`/`join` where clearer.
- **Prefer `if let` / `let ... else` over single-arm `match`.**

## Pass 4 — API & types (for anything `pub`)

- **Domain newtypes** over bare `u64`/`String` ids ("parse, don't
  validate" at the boundary).
- `#[must_use]` on `Result`-returning and builder methods;
  `#[non_exhaustive]` on enums/structs likely to grow.
- **Public error types:** a `thiserror` enum, NOT `Box<dyn Error>` or
  `String` (callers can't match on those). `anyhow` only at binary
  boundaries, not in a library's public API.
- **Trait choices:** implement `From` (gets `Into` free); derive
  `Debug`/`Clone`/`PartialEq` where reasonable; `Copy` only on small POD.
- Gate `serde` derives behind a feature in libraries.

## Pass 5 — consistency (within THIS codebase)

Idiom is partly local — match what the surrounding code already does:

- **Naming:** `snake_case` fns/vars, `CamelCase` types, `SCREAMING_CASE`
  consts; getters as `foo()` not `get_foo()`; conversions named
  `as_`/`to_`/`into_` per their cost convention. Flag drift from the
  file's existing names.
- **Error strategy:** does the new code use the same error type / crate
  (`thiserror` vs `anyhow`) as its module? Flag a new ad-hoc strategy.
- **Logging:** same facade as the rest of the crate (`tracing` vs `log`);
  flag a stray `println!`/`eprintln!` for diagnostics.
- **Module layout, import grouping, re-export style:** match the crate's
  established pattern rather than introducing a new one.
- **Test style:** inline `#[cfg(test)] mod tests` vs `tests/` — follow
  the crate's convention.

## Pass 6 — performance (flag, don't micro-optimize)

- Needless allocation in hot paths (`collect()` then iterate again;
  `Vec` where an iterator suffices); missing `Vec::with_capacity(n)`
  when `n` is known; `.clone()` of large owned data per loop iteration.
- Large enum variants bloating every value (box the big variant).
- Only raise perf items that are clearly on a hot path or obviously
  wasteful — don't bikeshed cold-path allocations.

## Output

Group findings by severity (correctness > idiom/API > consistency >
perf), each as `file:line — problem — suggested fix`. If a pass is
clean, say so explicitly. Cross-check against the repo's `AGENTS.md` and
its existing conventions. Don't narrow to one crate unless asked.
