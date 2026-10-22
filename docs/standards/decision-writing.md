# Writing a decision for the Director

This standard covers every question a person is asked, whatever raises it: an agent's
`linear_request_human_action`, a plan's open choices, a rework that failed the same way twice, and
the requests Symphony raises itself. Each one goes through one writer
(`SymphonyElixir.DecisionRequest`), which checks it against this standard, records it and shows it
in the Inbox with "Answer in my own words"; the answer is written into the ticket's Decisions
section, which every later run reads. A decision request is read by the Director in the Inbox. The Director decides like a film director: they want the picture
brighter or darker, not the f-stop. Every field of a request is written in their words.

This is the standard. The tool description and the agent instructions repeat it, and the tool
refuses the parts of it a machine can check (see [What the tool refuses](#what-the-tool-refuses)).

## The rules

1. **The question stands alone.** Someone who reads only the question knows what is being decided.
   Name each ticket by its identifier and a short name the first time
   ("TP-891 (Remove the retired review states)"), and explain any term a director wouldn't know in
   the same sentence.
2. **No code.** No file names or paths, code identifiers, branch names, commit hashes, template
   syntax or backticks. No internal jargon either: "partials", "head", "verdict", "hold", "feed". Say what
   a thing does, not where it lives or what it is called in the code. A pull request is
   "PR #448".
3. **`why` is short.** At most two short paragraphs, one fact per sentence, subject first.
4. **Each option's `effect` says what will happen to the work**, in the Director's terms: what
   moves, what waits, what ships.
5. **Say what waits.** `if_unanswered` says what waits or repeats until someone answers. It is
   required.
6. **Weigh the options.** Each option may carry up to three trade-offs, each one line:
   `good` (what it gains), `cost` (what it takes) and `risk` (what may go wrong).
   `decision.recommendation_reason` says in one line why the recommended option is the one; it is
   required.

The request is still a decision: one question, 2 to 4 options, exactly one recommended.

## An example

The TP-892 request, as it reached the Inbox:

> **Settle the legacy partials scope for TP-892**
>
> **Why:** Code Review sent PR #448 back again (head 2f5af5ab). Its only finding is that the legacy
> partials (parent_tickets.liquid, plan_pipeline.liquid, review_brief.liquid) still describe the
> Final verification flow. You ruled at 05:48 that these stay for TP-891. The reviewer says it will
> accept that only if the ticket's scope defers them, so handing back the same head will draw the
> same verdict.
>
> **Question:** How should TP-892 handle the legacy partials that Code Review keeps flagging?
>
> 1. **Defer them to TP-891 in the ticket scope** (recommended): You add a line to TP-892's
>    description deferring the legacy partials and legacy {% else %} instruction branches to
>    TP-891. The next run hands PR #448 back to Code Review unchanged.
> 2. **Strip them in PR #448 now**: The next run removes the Final verification and Supervisor
>    check text from the legacy partials, regenerates the legacy preview snapshot and pushes. This
>    overlaps TP-891's PR #454 and will conflict with it.
> 3. **Wait for TP-891 to merge**: Once TP-891 lands, the next run syncs main into auto/TP-892,
>    which drops the legacy partials, and pushes. That push hands it back to Code Review.

What is wrong with it: the question names "legacy partials" and a ticket the Director has never
seen; the why cites a commit hash and three file names; "head" and "verdict" are jargon; the
options name template syntax and a branch; nothing says what happens if nobody answers.

The same request, rewritten:

> **Let TP-892 ship without the old instructions' Final verification text**
>
> **Question:** TP-892 (Remove the Final verification and Supervisor check flows) keeps failing
> Code Review because the older set of agent instructions still describes the Final verification
> step. Should TP-892 leave that text to TP-891 (Remove the retired review states), which deletes
> it anyway?
>
> **Why:** Code Review sent PR #448 back a second time. Its only finding is the old Final
> verification text. You decided earlier today that TP-891 removes it. The reviewer accepts that
> only if TP-892's description says so.
>
> **If unanswered:** TP-892 stays in Rework. Each time it goes back to Code Review unchanged, it is
> sent back for the same reason.
>
> 1. **Leave it to TP-891** (recommended): You add one line to TP-892's description saying TP-891
>    removes the old text. TP-892 goes back to Code Review with no code change.
>    - Good: TP-892 can merge today.
>    - Cost: The old instructions describe a step that no longer exists until TP-891 lands.
> 2. **Remove it in TP-892 now**: The next run deletes the old text and goes back to Code Review.
>    - Good: TP-892 is complete on its own.
>    - Risk: TP-891's PR #454 changes the same text, so whichever merges second needs its clash
>      fixed.
> 3. **Wait for TP-891**: TP-892 waits until TP-891 merges, takes in its changes and goes back to
>    Code Review.
>    - Cost: TP-892 waits as long as TP-891 does.
>
> **Why recommended:** It is one line of text, and it lets TP-892 merge without touching TP-891's
> work.

## What the tool refuses

Before it posts, the writer refuses a request with no `if_unanswered` or no recommendation reason,
and one whose title, question, why, `if_unanswered`, `unblocks`, recommendation reason, option
labels, effects or trade-offs hold:

- backticks;
- template syntax: `{%` or `%}`;
- a path or a file name with an extension: `foo.ex`, `lib/…`, `*.liquid`, `.md`, a link;
- a commit hash: a run of 7 to 40 hex characters with both a digit and a letter;
- a branch name: `auto/…` or `origin/…`;
- an internal word: "head", "verdict", "hold" or "feed" (and their plurals).

An agent's request is refused with the `invalid_human_action` error; Symphony's own requests are
written to pass, and the text they quote from elsewhere (a ticket's title, a failure's reason) is said
in plain words before it is quoted. The `invalid_human_action` error names each token and its field and asks for plain words. Ticket
identifiers (`TP-891`), PR numbers (`#448`, `PR #448`), numbers and ordinary sentences pass.

The rest of the standard (a question that stands alone, the rest of the jargon, short sentences) is
not something a machine can check; it is on the writer.

## How the request is stored

The request is a `## Decision needed:` comment on the ticket, which Symphony reads back after a
restart:

```md
## Decision needed: Let TP-892 ship without the old instructions' Final verification text

**Question:** TP-892 (Remove the Final verification and Supervisor check flows) keeps failing …
**Why:** Code Review sent PR #448 back a second time. …
**If unanswered:** TP-892 stays in Rework. …

**Options:**
1. **Leave it to TP-891** (recommended): You add one line to TP-892's description …
   - Good: TP-892 can merge today.
   - Cost: The old instructions describe a step that no longer exists until TP-891 lands.
2. **Remove it in TP-892 now**: The next run deletes the old text …
   - Good: TP-892 is complete on its own.
   - Risk: TP-891's PR #454 changes the same text, so whichever merges second needs its clash fixed.

**Why recommended:** It is one line of text, and it lets TP-892 merge without touching TP-891's work.
```

An older comment's `**Time:**` line still reads, and is ignored: the time estimate is gone.
