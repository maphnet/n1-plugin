# Question Format

Use this format for every prompt that marks an option `(Recommended)` or `(not recommended)`, whether asked live or written into skill text. Prompts with no recommendation keep the verbatim sentence "No recommendation. The options are equivalent given the available evidence; select based on team preference." above the options, and mark nothing.

## Layout

    <question, one line>
    1 — <option> (Recommended): <evidence>
    2 — <option>: works when <condition>
    3 — <option>: works when <condition>

## Rules

- Mark at most one option `(Recommended)`. Give its evidence right after the mark: a file:line, a config default or a detected fact. A design decision (architecture, public API, data model, security) needs external evidence, per the recommended-option project rule; that rule wins on conflict.
- Give every other option one line, `<option>: works when <condition>`. State when it is the better pick; do not argue against it.
- A `(not recommended)` mark states its reason in the same line: `<option> (not recommended): <reason>`. Use it only where the recommended option is a fixed, unmarked default and the marked option is the discouraged one.
- Notes and evidence never repeat the marker text; only the mark itself carries it, because tools match on the marker.
- Compact one-line prompts keep the mark and a short reason; the per-option notes go in the step that expands the prompt, or are omitted when the line cannot hold them.
- Always write the marker as `(Recommended)` (capital R). Lowercase or bare-word forms are not recognised in headless runs.

## What earns the label

- Right, not quick: mark the option you would pick if you had to maintain this code for a year. A right option that costs more keeps the mark; name its cost in the evidence.
- Test: asked "which one is right?", you must name the same option. If you would not, the mark is wrong: move it, or use the No-recommendation sentence.
- Exception: the quick option may carry the mark only when the right one waits on a decision this run does not own. Its evidence then says it is temporary, and the right fix is filed as a follow-up per `<N1_ROOT>/references/followup-filing.md`.
- Evidence for the mark follows the recommended-option project rule (see Rules); this section decides only which option gets it.
- Unattended runs always take the `(Recommended)` option, or the first option when none is marked (`skills/n1-start/procedures/autonomy-headless.md`), so a wrong mark is acted on with no human check. Stop-list prompts still escalate.

## Headless question JSON

A queue child adds the notes as an optional field next to `rationale`:

    {"ticket":"N1-1","step":"plan","category":"none","question":"...","options":["A","B"],"recommended":"A","rationale":"<evidence>","alternatives":{"B":"works when <condition>"}}

Keys are option labels and must match `options` exactly; leave out options without a note. Omit the field when there are no notes. Consumers show each note under its option and ignore keys that match no option.
