---
name: plan-editing
description: >-
  Edit an ai/plans/*.md document, such as bytecode.md or interpreter.md, while
  keeping it a shrinking work queue instead of a growing changelog.
---

# Editing `ai/plans/*.md`

A plan document under `ai/plans/` is a queue of work not yet done. It is not
a changelog, a diary, or a design-decision archive. Git history — the commit
that lands next to your plan edit — is the permanent record of what changed
and why. The plan only needs to say what's left.

## The rule

A commit that resolves a plan item must make the plan **shrink or hold flat
byte-for-byte on that item**, never grow via narration. If your diff to the
plan file has more added lines than removed lines, stop and ask: is every
added line describing *open, unstarted work*, or is some of it explaining
what you just did?

Concretely:

1. **Delete the resolved item.** Don't summarize it, don't leave a trophy
   paragraph explaining how it now works — just remove it. If a forward
   pointer is useful ("next candidate is X"), that's one clause, not a
   recap.
2. **Only add prose for a new, still-open fact** the next implementer needs
   before touching the same area — e.g. a caveat, a known-incomplete edge,
   a blocker you discovered. Keep it to 1-3 sentences. State it as a
   property of the *remaining* problem, not as a narrative of your fix.
3. **Never justify a fix by walking through its history.** If you need to
   explain why a caveat is real, state the caveat and, if truly necessary,
   name the reproducing shape in one clause — don't narrate the before/after
   values or the mechanism you built.

## Bad (real examples caught in review)

> A capturing delegate assigned into a class field (`tryClassPointerField`'s
> `Tdelegate` branch) or a dynamic-array element
> (`tryDynamicArrayElementAssign`'s `Tdelegate` branch) now routes through
> `heapEscapingDelegateOperandOffset`, the same heap-box-or-decline treatment
> `compileDelegateReturn` and `structLiteralReturnOffset` already gave...

This explains the mechanism of a fix that already landed. The commit message
already says this. Delete it.

> ...confirmed (not hypothetical): before the gate below existed,
> `int total = 40; c.next = () => total + 2; total = 100; return c;`
> silently returned 42 instead of SystemLinker's 102...

This narrates a bug's history to justify a caveat. The caveat itself
("a class-field/array-element write followed by further same-function
mutation before the aggregate escapes is unproven") is legitimate remaining
information; the "confirmed not hypothetical, here's what it used to return"
framing around it is not.

## Good

> The class-field/array-element further-mutation question is now a confirmed
> and declined shape, not an open question. Next candidate: [whatever is
> actually next].

One clause disposes of the resolved item; the forward pointer is the only
thing that survives.

## Self-check before committing

Run `git diff -- ai/plans/*.md` as your last step before committing. For
each added line, ask: does this describe work still to be done, or does it
describe work I just finished? If it's the latter, cut it — it belongs in
the commit message, not the plan. If the plan file's line count went up,
you should be able to point at the specific new caveat that justifies each
added line.

## Report-back note

If you're a subagent asked to report back to an orchestrator after this
commit, keep that report to facts the orchestrator needs to proceed (commit
hash, where the plan's next-candidate pointer now points). Composing a
narrative description of what you implemented for the report primes the
same narrative habit in the plan edit itself — don't let the two bleed
together. The commit message is where "what I did and why" belongs.
