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
