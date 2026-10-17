# Shared test helpers

Deterministic stand-ins and builders that CI and the QA agent share, so QA never writes its own
([ADR 0003](../../docs/adr/0003-automated-tests-first-qa-last-resort.md): automated tests first, QA
last resort). They are stdlib-only Python 3 (3.9 or later): no build step, runnable from a shell.

The Elixir suite is unaffected: `mix test` loads only `*_test.exs` files, and `mix.exs` names the
`.exs` support files it ignores, so no Python file here is loaded as a test or support file.

| Folder | What |
| --- | --- |
| `stubs/` | Platform-neutral HTTP stand-ins. `_server.py` is what they share: a server bound to `127.0.0.1` only that logs one JSON line per request. `update_feed.py` is the update feed; `gh.py` and `linear.py` are the gh and Linear stubs, answering from the committed files in `answers/`. |
| `macos_release/` | The signed macOS release N and N+1: the signing identity (`signing.py`), the throwaway minisign key pair (`minisign_keys.py`) and the pair's build (`release_pair.py`). |
| `tests/` | The helpers' own `unittest` tests. |

The other files here (`test_support.exs`, `snapshot_support.exs`, `dev_server.py`, `appkit_probe/`,
`live_e2e_docker/`) belong to the Elixir suite.

## Tests

```bash
make support-test   # python3 -m unittest discover -s test/support/tests
```

No build, no sudo, no signing: the release pair is tested on made-up inputs. The required `macos`
workflow runs them whenever a Python file under `test/support/` or a file under `test/support/stubs/answers/` changes.

## The release pair

```bash
make -C macos release-pair                  # or, from the repo root:
python3 test/support/macos_release/release_pair.py [--out DIR] [--build-n N] [--build-n1 N1] [--minisign-dir DIR]
```

Builds release N and its update N+1 of Symphony.app from the checkout (`make release` and
`swift build -c release`, then `make -C macos bundle` for each), signs both with one code-signing
identity, packages N+1 with `scripts/release/package.sh` signed with a throwaway minisign key, and
writes these fixed paths under `macos/build/release-pair/` (or `--out`, `RELEASE_PAIR_OUT` for
`make`):

| Path | What |
| --- | --- |
| `N/Symphony.app` | Release N, signed, with the pair's minisign public key in its Info.plist. |
| `feed/Symphony-<v>.zip` | N+1's app, as a release ships it. |
| `feed/Symphony-<v>.zip.sha256`, `feed/Symphony-<v>.zip.minisig` | Its checksum and minisign signature. |
| `feed/version.json` | What the app reads to find the update. `published_at` is the commit's time, not the build's. |
| `feed/release_notes.md` | The release notes `package.sh` writes. |
| `minisign/minisign.pub`, `minisign/minisign.key` | The throwaway key pair (made new each run unless `--minisign-dir` is given). |
| `manifest.json` | Every path above (relative to the folder), the commit, the versions and build numbers, N+1's tag, the signing identity's SHA-1 and the minisign public key. |

Build numbers default to 90001 and 90002 (versions `0.0.1.90001` and `0.0.1.90002`):
`make -C macos release-pair RELEASE_PAIR_BUILD_N=70001 RELEASE_PAIR_BUILD_N1=70002`, or
`--build-n`/`--build-n1`. With the same commit, build numbers, keys and identity, the paths,
`version.json` (but for the zip's checksum: a signature carries its signing time) and
`manifest.json` are the same; nothing in a path is a time or a random name.

It needs macOS with `swift`, `codesign`, `ditto`, `plutil`, `minisign`, `git`, `make`, `jq` and
`security`, and the repository's `mise` toolchain for `make release`.

### Signing identity

Only test identities: never Symphony's release key or signing certificate.

| Variable | Effect |
| --- | --- |
| *(none set)* | A throwaway self-signed code-signing identity in a temporary keychain, on the keychain search list until the build ends. `codesign --verify` accepts it only once it is trusted for code signing. |
| `SYMPHONY_E2E_SIGNING_IDENTITY` | Sign with this identity instead (a name or its SHA-1), such as a QA host's persistent test identity (`scripts/qa/install-test-signing-identity.sh`, which the QA driver's `qa_build_release_pair` signs with). |
| `SYMPHONY_E2E_KEYCHAIN` | The keychain that holds that identity, when it isn't on the search list. |
| `SYMPHONY_E2E_TRUST_CERT=1` | Trust the throwaway certificate for code signing until the build ends (`sudo security add-trusted-cert`; CI sets this). |

`make release-pair` removes a throwaway identity when it ends, so the N it built accepts N+1 only
while that certificate is trusted: to install the pair later, sign it with a persistent test
identity. The e2e keeps its throwaway identity until the test ends.

### Prebuilt inputs

| Variable | Effect |
| --- | --- |
| `SYMPHONY_E2E_SYMPHONY_RELEASE_N`, `SYMPHONY_E2E_SYMPHONY_RELEASE_N1` | Use these release directories (`_build/prod/rel/symphony`, built with the matching `SYMPHONY_BUILD_NUMBER`) instead of `make release`. |
| `SYMPHONY_E2E_APP_EXECUTABLE` | Use this `SymphonyBar` executable instead of `swift build -c release`. |
| `SYMPHONY_E2E_BUILD_N` | The default for `--build-n`. |

From Python (the e2e does this), with `test/support` on `sys.path`:

```python
from macos_release import minisign_keys, release_pair, signing

with signing.select(work / "signing") as identity:
    pair = release_pair.Layout(work / "release-pair")
    keys = minisign_keys.generate(pair.minisign)
    manifest = release_pair.build(pair.root, identity, keys, 90001, 90002)
```

## The update feed

```bash
python3 test/support/stubs/update_feed.py --dir macos/build/release-pair/feed --port 8123 --log feed.log
```

Answers `GET /releases/latest` like GitHub's API (`tag_name`, `html_url`, `body`, `assets` with
`browser_download_url`) and serves the release's assets. Point the app at it with
`SYMPHONY_BAR_UPDATE_URL=http://127.0.0.1:<port>/releases/latest`; `qa_launch_app`'s
`update_feed_port` sets that. It prints `update feed on <url> (mode …, log …)` when it is ready, and
stops on SIGINT or SIGTERM.

| Mode | `releases/latest` answers |
| --- | --- |
| `publish` (default) | The feed's release: N+1 from `--dir`, or the `--fake-release`. |
| `none` | No newer release: the app's own release N, so a check finds the app up to date. Its `version.json` is served; its app is listed but not served (a check never downloads it). |
| `forbidden` | HTTP 403, which the app reads as GitHub's rate limit. |

Switch the mode while it runs: `curl -X POST --data none http://127.0.0.1:<port>/_feed/mode`
(`GET /_feed/mode` says the current one; an unknown mode is a 400).

| Option | Effect |
| --- | --- |
| `--dir DIR` | The release's assets: `version.json`, the zip it names, `.sha256`, `.minisig`, `release_notes.md` (a release pair's `feed/`). Every file in it is served at `/<name>`. |
| `--fake-release VERSION BUILD` | Offer a made-up newer release with no build instead, for checks of what the app shows: its `version.json` is served, its zip and checksum are 404s. Needs no `--dir`. |
| `--current VERSION BUILD` | The app's own release, which `none` serves. Default: N from the `manifest.json` next to `--dir`. `none` is refused without one. |
| `--mode MODE` | The starting mode. |
| `--port PORT` | The port on `127.0.0.1` (default: a free one). It never binds another address. |
| `--log FILE` | Append one JSON line per request: `{"method", "path", "status", "time"}`, and `"body"` for a POST. |

From Python: `UpdateFeed(folder, fake=None, current=None, mode="publish", port=0, log=None).start()`,
then `set_mode`, `latest_url`, `latest_requests` (how many checks it answered), `requests` (the log)
and `stop()`.

## The gh and Linear stubs

```bash
python3 -B test/support/stubs/gh.py --port 8124 --log gh.log
python3 -B test/support/stubs/linear.py --port 8125 --log linear.log
```

What the app's GitHub and Linear calls reach in QA, in place of the real services. `qa_launch_app`'s
`gh_stub_port` makes the app run Symphony's fake `gh`, which POSTs each call to
`http://localhost:<port>` as a form body (`argc`, then one `arg` per argument, in order) and prints
the answer: a 200 on stdout with exit status 0, anything else on stderr with exit status 1.
`linear_stub_port` points the app's Linear queries at `http://localhost:<port>/graphql`. Each stub
prints `gh stub on <url> (…)` or `Linear stub on <url>/graphql (…)` when it is ready, and stops on
SIGINT or SIGTERM.

| Stub | Answers | An unknown call |
| --- | --- | --- |
| `gh.py` | `POST /` with the fake `gh`'s form body: the first entry of `answers/gh.json` whose `args` match the call, one by one. A `*` inside an argument matches any text (such as a pull request's body); everything else matches only itself. | 404 with `gh stub: no committed answer for: gh …`, which the fake `gh` prints on stderr. A body that is not a call is a 400. |
| `linear.py` | `POST /graphql` with `{"query", "variables"}` JSON: the answer `answers/linear.json` has for the query's operation name (`operationName`, else the name after `query`). Any API key works. | 400 with a GraphQL error naming the operation, in `message` and `extensions.userPresentableMessage`, which the app shows. A body that is not GraphQL is a 400, another path a 404. |

The committed answers:

- `answers/gh.json`: the Add Repo sheet's calls for the repo `acme/widgets`. Its probe answers
  default branch `main` and the top-level files `README.md`, `mix.exs` (with Credo) and `mix.lock`;
  opening the `WORKFLOW.md` pull request answers the base commit, the `symphony/add-workflow`
  branch, the commit, the pull request `https://github.com/acme/widgets/pull/1`, and deleting the
  branch after a failure. Each entry is `{"args": [...], "status": 200, "output": "..."}`; `status`
  defaults to 200.
- `answers/linear.json`: `SymphonyBarProjects` (one project, `QA Project`),
  `SymphonyBarProjectTeams` (one team) and `SymphonyBarLabels` (one label, `macos`), under
  `{"answers": {"<operation name>": <the response body>}}`.

| Option | Effect |
| --- | --- |
| `--answers FILE` | Answer from this file instead of the committed one. |
| `--port PORT` | The port on `127.0.0.1` (default: a free one). It never binds another address. |
| `--log FILE` | Append one JSON line per request: `{"method", "path", "status", "time"}`, with the call (`"args"` for gh; `"operation"` and `"variables"` for Linear, never the `Authorization` header), or `"body"` when it could not be read as one. |

From Python: `GhStub(answers=ANSWERS, port=0, log=None).start()` or
`LinearStub(answers=ANSWERS, port=0, log=None).start()`, then `url` (`graphql_url` for Linear),
`requests` (the log) and `stop()`.
