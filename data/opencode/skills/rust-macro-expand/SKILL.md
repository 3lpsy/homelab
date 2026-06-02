---
name: rust-macro-expand
description: Use cargo-expand to inspect derive/proc-macro output before guessing at compiler errors that mention generated code.
---
# rust-macro-expand

When a compiler error mentions a derive macro, attribute macro, or a
type that's clearly synthesized (e.g. `<MyType as Serialize>::serialize`
and the user didn't write a `Serialize` impl), expand the macro first:

    cargo +nightly expand --package <crate> <path>

Common forms:
- Whole binary: `cargo +nightly expand --package <crate> --bin <bin>`
- Whole lib:    `cargo +nightly expand --package <crate> --lib`
- One module:   `cargo +nightly expand --package <crate> <module::path>`

Pipe through `| head -200` to keep the output context-friendly. If the
expansion is huge, look at the specific item with the `--package` /
module path narrowed.

Don't speculate about what `#[derive(Foo)]` generates — read it.
