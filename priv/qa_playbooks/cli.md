### Playbook: cli

Exercise the command-line entry points this change touches, the way a user would.

1. Find how the project builds and runs its CLI: read `AGENTS.md`, `README.md` and the
   `Makefile` (for an Elixir escript this is usually `mix deps.get` then `mix build` or
   `mix escript.build`, producing `bin/<name>`). Build it once.
2. Work only in throwaway locations. Put any config files, state roots, logs and `HOME`
   overrides under `$TMPDIR` (for example `export HOME="$TMPDIR/qa-home"`). Never point
   the CLI at a real user config, a real state directory, or a production service.
3. Run every command from the ticket's `## User walkthrough` in order. When there is
   no walkthrough, run each changed entry point with its documented happy path, then
   with one invalid input (missing file, bad flag, malformed config) and check that
   the error is clear and the exit status is non-zero.
4. For each command record the exact command line, its exit status and the relevant
   output. Append them to `qa-evidence/cli-transcript.md` as fenced blocks:

   ```text
   $ bin/symphony check --config "$TMPDIR/qa/symphony.yml"
   exit: 0
   <output>
   ```

5. Compare what you saw with the acceptance criteria. Any mismatch between the
   documented or expected behaviour and the actual output is a failing step.
6. Attach `qa-evidence/cli-transcript.md` to the issue with `linear_attach_file` and
   put the returned URL in the step's `evidence` list.

Do not run long-lived services (`symphony` without a subcommand starts the
orchestrator); when a walkthrough step needs one, start it with a short timeout and
stop it before moving on.
