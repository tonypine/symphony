defmodule SymphonyElixir.AcceptanceGate.EscalationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AcceptanceGate.Escalation
  alias SymphonyElixir.AcceptanceGate.Settings.Escalate
  alias SymphonyElixir.DependencyAudit.MixParser
  alias SymphonyElixir.Linear.Issue

  @rules %Escalate{}

  defp issue(attrs \\ []) do
    struct!(%Issue{id: "issue-1", identifier: "TP-1", title: "Add a button", description: "Adds a button to the toolbar.", labels: ["feature"]}, attrs)
  end

  defp file(path, attrs \\ []) do
    Map.merge(%{path: path, additions: 10, deletions: 2, added_lines: ["def ok, do: :ok"]}, Map.new(attrs))
  end

  defp diff(files), do: %{files: files}

  defp check(opts) do
    Escalation.check(
      Keyword.get(opts, :issue, issue()),
      diff(Keyword.get(opts, :files, [file("lib/app/button.ex")])),
      Keyword.get(opts, :busy_files, []),
      Keyword.get(opts, :rules, @rules)
    )
  end

  defp rules(fields), do: struct!(@rules, fields)

  defp lock(entries) do
    "%{\n" <> Enum.map_join(entries, ",\n", fn {name, version} -> ~s(  "#{name}": {:hex, :#{name}, "#{version}", "hash", [:mix], [], "hexpm", "hash"}) end) <> "\n}\n"
  end

  defp package_json(deps), do: Jason.encode!(%{"name" => "web", "dependencies" => deps})

  test "ticket_reasons/2 checks only the ticket's label and pattern rules" do
    assert Escalation.ticket_reasons(issue(), @rules) == []

    assert [%{rule: :label}, %{rule: :ticket_pattern, detail: detail}] =
             Escalation.ticket_reasons(issue(labels: ["needs-human"], description: "Needs a manual review."), @rules)

    assert detail =~ "manual"
  end

  test "a clean diff returns no reasons" do
    assert check([]) == []
    assert Escalation.check(issue(), diff([]), [], @rules) == []
  end

  test "label" do
    assert check(issue: issue(labels: ["feature", " Needs-Human "])) == [%{rule: :label, detail: "the issue is labelled ` Needs-Human `"}]
    assert check(issue: issue(labels: ["needs-human", "breakdown"])) == [%{rule: :label, detail: "the issue is labelled `needs-human`; the issue is labelled `breakdown`"}]
    assert check(issue: issue(labels: ["risky"]), rules: rules(labels: ["risky"])) == [%{rule: :label, detail: "the issue is labelled `risky`"}]
  end

  test "ticket pattern, in the title or the description" do
    assert [%{rule: :ticket_pattern, detail: "the ticket matches `(?i)\\b(human|manual(ly)?)\\s+review`"}] =
             check(issue: issue(description: "Ship it after a Manual review of the copy."))

    assert [%{rule: :ticket_pattern, detail: detail}] = check(issue: issue(title: "Needs human sign-off", description: nil))
    assert detail =~ "needs?[- ]human"

    assert [%{rule: :ticket_pattern}] = check(issue: issue(description: "This must not auto-merge."))
    assert check(issue: issue(title: nil, description: nil)) == []
  end

  test "path glob, ignoring docs and tests" do
    assert check(files: [file("lib/app/auth/session.ex")]) == [%{rule: :path, detail: "lib/app/auth/session.ex matches `**/*auth*/**`"}]

    assert check(files: [file(".github/workflows/ci.yml"), file("priv/repo/migrations/1_add.exs")]) == [
             %{rule: :path, detail: ".github/workflows/ci.yml matches `.github/workflows/**`; priv/repo/migrations/1_add.exs matches `**/migrations/**`"}
           ]

    assert check(files: [file("test/app/auth_test.exs"), file("docs/tokens.md")]) == []
    assert check(files: [file("api/billing/charge.ex")], rules: rules(paths: ["api/billing/**"])) == [%{rule: :path, detail: "api/billing/charge.ex matches `api/billing/**`"}]
  end

  test "diff pattern on added lines only" do
    added = file("lib/app/cleanup.ex", added_lines: ["  # tidy up", ~s|  System.cmd("sh", ["-c", "rm -rf /tmp/x"])|])

    assert check(files: [added]) == [
             %{rule: :diff_pattern, detail: ~s|lib/app/cleanup.ex adds a line matching `\\brm\\s+-rf\\b`: System.cmd("sh", ["-c", "rm -rf /tmp/x"])|}
           ]

    long = file("priv/repo/seeds.sql", added_lines: ["DELETE FROM users WHERE " <> String.duplicate("x", 200)])
    assert [%{rule: :diff_pattern, detail: detail}] = check(files: [long])
    assert detail =~ "priv/repo/seeds.sql adds a line matching `(?i)\\bdelete\\s+from\\b`: DELETE FROM users WHERE xxx"
    assert String.ends_with?(detail, "...")

    # A file that only removes a matching line has no added lines.
    assert check(files: [file("lib/app/cleanup.ex", added_lines: [])]) == []
    assert check(files: [%{path: "lib/app/cleanup.ex", additions: 0, deletions: 1}]) == []
  end

  describe "dependency" do
    test "a major bump or a new dependency in mix.lock" do
      base = lock(jason: "1.4.4", plug: "1.18.0", req: "0.4.0")
      mix_lock = file("mix.lock", base: base, head: lock(jason: "2.0.0", plug: "1.19.1", req: "0.5.0", bandit: "1.6.0"))

      assert check(files: [mix_lock]) == [
               %{rule: :dependency, detail: "mix.lock: new dependency bandit 1.6.0; mix.lock: jason 1.4.4 -> 2.0.0; mix.lock: req 0.4.0 -> 0.5.0"}
             ]
    end

    test "a major bump or a new dependency in package.json" do
      json = file("web/package.json", base: package_json(%{"react" => "^18.2.0", "zod" => "~3.22.0"}), head: package_json(%{"react" => "^19.0.0", "zod" => "~3.23.0", "left-pad" => "1.3.0"}))

      assert check(files: [json]) == [
               %{rule: :dependency, detail: "web/package.json: new dependency left-pad 1.3.0; web/package.json: react ^18.2.0 -> ^19.0.0"}
             ]

      assert check(files: [file("package.json", base: nil, head: package_json(%{"react" => "^18.2.0"}))]) == [
               %{rule: :dependency, detail: "package.json: new dependency react ^18.2.0"}
             ]
    end

    test "a minor bump passes under major, and escalates under any with removals" do
      mix_lock = file("mix.lock", base: lock(jason: "1.4.4", plug: "1.18.0"), head: lock(jason: "1.4.5"))

      assert check(files: [mix_lock]) == []

      assert check(files: [mix_lock], rules: rules(dependencies: "any")) == [
               %{rule: :dependency, detail: "mix.lock: jason 1.4.4 -> 1.4.5; mix.lock: removes plug"}
             ]

      assert check(files: [mix_lock], rules: rules(dependencies: "off")) == []
    end

    test "a version without a number counts as a major change, and other sources keep their spec" do
      head = %{
        "dependencies" => %{"react" => "latest", "zod" => "^3.23.0", "a" => "github:o/a", "b" => "file:../b", "c" => "https://npm.example.com/c.tgz", "d" => 1},
        "devDependencies" => %{"e" => "git+ssh://weird"}
      }

      json = file("package.json", base: package_json(%{"react" => "^18.2.0", "zod" => "next"}), head: Jason.encode!(head))

      assert [%{rule: :dependency, detail: detail}] = check(files: [json])

      assert detail ==
               Enum.join(
                 [
                   "package.json: new dependency a github:o/a",
                   "package.json: new dependency b file:../b",
                   "package.json: new dependency c https://npm.example.com/c.tgz",
                   "package.json: new dependency d non_string_spec",
                   "package.json: new dependency e git+ssh://weird",
                   "package.json: react ^18.2.0 -> latest",
                   "package.json: zod next -> ^3.23.0"
                 ],
                 "; "
               )
    end

    test "a changed git ref, URL or path counts as a major change even when its first digits match" do
      git_lock = fn ref -> ~s(%{\n  "foo": {:git, "https://github.com/o/foo.git", "#{ref}", [branch: "main"]}\n}\n) end
      mix_lock = file("mix.lock", base: git_lock.("3f2a0c1"), head: git_lock.("3e9b7d4"))

      assert check(files: [mix_lock]) == [%{rule: :dependency, detail: "mix.lock: foo git:3f2a0c1 -> git:3e9b7d4"}]

      json =
        file("package.json",
          base: package_json(%{"a" => "github:o/a#1f00", "b" => "https://npm.example.com/b-1.0.0.tgz", "c" => "file:../c1"}),
          head: package_json(%{"a" => "github:o/a#1abc", "b" => "https://npm.example.com/b-1.2.0.tgz", "c" => "file:../c1-new"})
        )

      assert check(files: [json]) == [
               %{
                 rule: :dependency,
                 detail:
                   "package.json: a github:o/a#1f00 -> github:o/a#1abc; " <>
                     "package.json: b https://npm.example.com/b-1.0.0.tgz -> https://npm.example.com/b-1.2.0.tgz; " <>
                     "package.json: c file:../c1 -> file:../c1-new"
               }
             ]

      ranges = file("package.json", base: package_json(%{"a" => ">=1.0.0 <2.0.0", "b" => "v2.1.0"}), head: package_json(%{"a" => ">= 1.5.0", "b" => "v2.3.0"}))
      assert check(files: [ranges]) == []
    end

    test "a manifest that can't be parsed escalates" do
      assert check(files: [file("package.json", base: package_json(%{}), head: "{not json")]) == [%{rule: :dependency, detail: "package.json could not be parsed"}]
      assert check(files: [file("mix.lock", base: "%{", head: lock(jason: "1.4.4"))]) == [%{rule: :dependency, detail: "mix.lock could not be parsed"}]
    end
  end

  test "total size outside docs and tests" do
    files = [file("lib/app/big.ex", additions: 1400, deletions: 101), file("test/app/big_test.exs", additions: 5000), file("README.md", additions: 900)]

    assert check(files: files) == [%{rule: :size, detail: "1501 lines change outside docs and tests (limit 1500)"}]
    assert check(files: [file("lib/app/big.ex", additions: 1400, deletions: 100)]) == []
  end

  test "busy file size" do
    files = [file("lib/app/router.ex", additions: 250, deletions: 51), file("lib/app/other.ex", additions: 400)]

    assert check(files: files, busy_files: ["lib/app/router.ex"]) == [
             %{rule: :busy_file, detail: "lib/app/router.ex is a busy file and 301 of its lines change (limit 300)"}
           ]

    assert check(files: [file("lib/app/router.ex", additions: 300, deletions: 0)], busy_files: ["lib/app/router.ex"]) == []
  end

  describe "a new symphony.yml setting" do
    @schema "lib/symphony_elixir/config/schema.ex"
    @system_schema "lib/symphony_elixir/config/system_schema.ex"
    @manifest "macos/Sources/SymphonyBarCore/SettingsUIManifest.swift"

    test "escalates a schema field or key list the macOS app's manifest doesn't follow" do
      files = [
        file(@schema, added_lines: ["# A new cap.", "      field(:max_widgets, :integer, default: 3)"]),
        file(@system_schema, added_lines: [~s|    "agent.limits" => ~w(max_turns max_widgets),|])
      ]

      assert check(files: files) == [
               %{
                 rule: :settings_ui,
                 detail:
                   "#{@schema} declares a setting without a change to #{@manifest}: field(:max_widgets, :integer, default: 3); " <>
                     ~s|#{@system_schema} declares a setting without a change to #{@manifest}: "agent.limits" => ~w(max_turns max_widgets),|
               }
             ]

      assert check(files: [file(@schema, added_lines: ["      embeds_many(:widgets, Widget)"])]) |> Enum.map(& &1.rule) == [:settings_ui]
    end

    test "passes when the manifest changes too, or the schema change declares no setting" do
      assert check(files: [file(@schema, added_lines: ["field(:max_widgets, :integer)"]), file(@manifest)]) == []
      assert check(files: [file(@schema, added_lines: ["    |> validate_number(:max_widgets, greater_than: 0)"])]) == []
      assert check(files: [file(@schema), file("lib/app/schema.ex", added_lines: ["field(:name, :string)"])]) == []
    end
  end

  test "returns one reason per triggered rule, in rule order" do
    files = [
      file("lib/app/auth/session.ex", additions: 1600, added_lines: ["rm -rf build"]),
      file("mix.lock", additions: 1, deletions: 1, base: lock(jason: "1.4.4"), head: lock(jason: "2.0.0")),
      file("lib/symphony_elixir/config/schema.ex", added_lines: ["field(:max_widgets, :integer)"])
    ]

    reasons = check(issue: issue(labels: ["needs-human"], description: "Needs human review."), files: files, busy_files: ["lib/app/auth/session.ex"])

    assert Enum.map(reasons, & &1.rule) == [:label, :ticket_pattern, :path, :diff_pattern, :dependency, :size, :busy_file, :settings_ui]
  end

  describe "MixParser.parse_lock/1" do
    test "reads Hex versions and other SCMs' refs without creating atoms" do
      content = """
      %{
        "bar" => {:hex, :bar},
        1 => :odd,
        "jason": {:hex, :jason, "1.4.4", "abc", [:mix], [], "hexpm", "def"},
        "foo": {:git, "https://github.com/o/foo.git", "0123abc", [branch: "main"]}
      }
      """

      assert MixParser.parse_lock(content) == {:ok, %{"jason" => "1.4.4", "foo" => "git:0123abc", "bar" => "unknown", "1" => "unknown"}}
      assert MixParser.parse_lock("[1, 2]") == {:error, :lock_not_a_map}
      assert {:error, _reason} = MixParser.parse_lock("%{")
    end
  end
end
