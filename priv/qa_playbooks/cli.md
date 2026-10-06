### Playbook: cli

Exercise the command-line entry points this change touches, the way a user would.
Do not run the project's test suite, `make all`, coverage or Dialyzer: CI already ran them.
Judge the change only by what the commands do.

1. Find how the project builds and runs its CLI: read `AGENTS.md`, `README.md` and the
   `Makefile` (for an Elixir escript this is usually `mix deps.get` then `mix build` or
   `mix escript.build`, producing `bin/<name>`). Build it once.
2. Work only in throwaway locations. Put any config files, state roots, logs and `HOME`
   overrides under `$TMPDIR` (for example `export HOME="$TMPDIR/qa-home"`). Never point
   the CLI at a real user config, a real state directory, or a production service.
   Never use a real OpenRouter key. When a step touches OpenRouter (`OPENROUTER_API_KEY`, a
   `provider: openrouter` profile, its models check or run), run it against the stub: in the
   same shell command as the steps that need it, start
   `bin/symphony openrouter-stub > "$TMPDIR/openrouter-stub.log" 2>&1 &`, read the URL from the
   log's first line, export `SYMPHONY_BAR_QA_ROOT="$TMPDIR/qa-root"`,
   `SYMPHONY_QA_OPENROUTER_URL=<that URL>` and `OPENROUTER_API_KEY=sk-or-v1-symphony-qa-stub`
   (a made-up key, safe to quote), and `kill` the stub at the end of the command. The stub
   lists `symphony-qa/reasoning-tools` (tools and reasoning), `symphony-qa/tools-only` (tools,
   no reasoning) and `symphony-qa/no-tools` (no tools), rejects any other key, and answers each
   `claude` request with a canned message naming the model. Its log has a line per request
   (path, model, key accepted or rejected): quote it to show a run's model and key reached
   OpenRouter. To show a real `claude` run through Symphony's OpenRouter launch path accepts
   the stub's answer, run `mix test --only real_claude
   test/symphony_elixir/claude_code/real_claude_openrouter_test.exs` where `claude` is
   installed (CI does not install it, so this one test file is the exception to not running
   the suite). It starts its own stub and a throwaway `HOME`, and prints the command, the exit
   status, the answer and the stub's request log: quote that block. Never mark a step
   `blocked` for want of a real key; checks with a real key are manual.
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
