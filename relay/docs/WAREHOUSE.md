# Holio challenge — warehouse training prototype

**Scope:** "Training: guidance in the worker's own language". This is a narrow demonstration
that guides a new worker through a single procedure. There is **no Holio API or integration**,
and Relay does not claim one.

## The procedure

`DemoProcedure` ("Receiving an inbound pallet at Dock B", 7 steps, 6 warnings, 13 anticipated
questions) was **written for this project**. It is demonstration material, not official Holio
documentation and not a real site procedure. Its Norwegian (bokmål) and Polish texts were also
written for the demo and have not been reviewed by a professional translator. A JSON copy is
in `docs/demo-procedure.json` (`relay-runner export-procedure`).

You can load a different procedure in the same JSON format: Warehouse Training ›
Procedure › Load…, or `relay-runner warehouse --procedure file.json`. Documents are validated
on load: they need steps, unique step IDs, source-language text for every instruction and
warning, and citations that point to existing steps.

## Behaviour

| Requirement | How |
|---|---|
| One step at a time | `TrainingSession` with start / next / back / repeat. |
| Answers from the supplied procedure | `ProcedureAnswerer` matches keywords against the author's anticipated questions, then falls back to strong word overlap with a single step. It only returns text that is in the document. |
| Show the supporting instruction | Every answer carries a `Citation` (step ID, title and the instruction quoted verbatim). |
| Ask for clarification | Vague questions ("what about it?") and ties between different steps return a clarification with the candidate steps. |
| Escalate | Topics the document marks out of scope (temperature-controlled goods, powered equipment and certification), and anything that can't be matched, are escalated to "the shift lead". A *Needs attention* task is created. |
| Preserve critical warnings across languages | Warnings are rendered in every language, critical ones first, and must be acknowledged before *Next*. If a translation is missing, the source-language warning is shown and marked. Tests check every warning × step × language, including a language with no translation. |

## What works without a model provider

Everything above. Matching is deterministic, so behaviour is predictable but literal: a
question phrased without any of the procedure's keywords is escalated rather than guessed.
Flexible paraphrase understanding, or translating procedures that were supplied in only one
language, would need a separate language-model provider. That is an explicit future
dependency and is not part of this milestone. If one is added, it should still answer only
with cited procedure text and leave warnings untouched.
