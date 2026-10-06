# Ticket templates

Symphony reads a ticket by its type, set by one label. Each type has a template here, so the
template the operator writes and the prompt that reads it change together
([ADR 0001](../adr/0001-director-workflow.md)).

| Type | Label | Template | Required sections |
| --- | --- | --- | --- |
| Bug | `type:bug` | [bug.md](bug.md) | Observed, Expected, Steps to reproduce |
| Feature | `type:feature` | [feature.md](feature.md) | Goal, Acceptance criteria |
| Plan | `plan` | [plan.md](plan.md) | None: a plan is never sent back |

What Symphony does with each type is in the `ticket_types` playbook partial
(`priv/playbook/ticket_types.liquid`), rendered by `WORKFLOW.md`:

- **Bug and feature tickets get a readiness check.** When a required section is missing or still
  holds only the template's italic hint, the run posts one comment naming the missing sections and
  moves the ticket to `Backlog`, without opening a PR. Fill them in and move the ticket to `Todo`
  again.
- **A bug run starts with a failing test** that reproduces the bug, then fixes it in the same PR.
- **A plan ticket is never sent back.** What is unclear becomes a decision with a recommended
  default in its review.
- **A ticket with no type label** gets the same prompt as before the types existed.
- When a ticket has more than one type label, `plan` wins over `type:bug`, and `type:bug` over
  `type:feature`.

## Create the labels

Do this once per workspace, before the templates.

1. In Linear, open **Settings → Workspace → Labels** (or **Settings → Teams → _team_ → Labels** for
   one team only).
2. Create `type:bug` and `type:feature` as plain labels, with the colon in the name. Do not put them
   in a label group named `type`: Linear then names the label `bug`, which Symphony does not read as
   a type.
3. Create `plan`, or rename an existing `breakdown` label to `plan` (Linear relabels every ticket
   that has it). Symphony accepts either name.

## Create the templates

Repeat for each of the three templates.

1. In Linear, open **Settings → Teams → _team_ → Templates** and choose **New template** (an issue
   template).
2. Name it after the type: `Bug`, `Feature` or `Plan`.
3. Open the matching file here, copy everything below its `---` line and paste it into the
   template's description.
4. Set **Labels** to the type's label: `type:bug`, `type:feature` or `plan`. Every ticket made from
   the template then carries it.
5. Leave the status empty (new tickets land in the team's default status) and save.

To make a template the default for new tickets, choose it under **Default templates** on the same
page. To create a ticket from one, open a new issue and pick the template from the template menu
in its top bar.

When a template here changes, update the Linear template the same way: paste the new description
over the old one.
