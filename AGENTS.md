# AGENTS.md

## Coding Style

- Prefer clear inline control flow over tiny one-off utility functions. Do not
  introduce a helper when its body is only one or two straightforward lines or
  it is used in only one local place
- Add a helper only when it represents a meaningful concept, is reused, isolates
  nontrivial behavior, or clearly reduces complexity without hiding simple
  local logic.
- Add type annotations for new or changed code where practical, especially for
  public APIs, parameters, return values, and non-obvious table shapes.

## Commit Messages & Communication

Write commit messages (and explanations to the user) in plain English for
the user, who has not read the code:

- Use complete sentences, not compressed jargon or dense noun phrases.
  Bad: "removing pairs-order nondeterminism". Good: "results no longer
  depend on the order the placeholders are listed in".
- Do not coin terminology (e.g. "walk-based expander", "placeholder DSL");
  say what the thing does instead.
