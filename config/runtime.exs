import Config

if config_env() == :prod do
  System.put_env("ERL_CRASH_DUMP_BYTES", "0")
  SymphonyElixir.Paths.set_state_root_from_env()
  SymphonyElixir.Paths.set_logs_root_from_env()
  # The Burrito binary boots the BEAM directly, without distribution, and never
  # sources rel/env.sh. Resolve the secure cookie here (state root must be
  # resolved first) so a bad cookie fails the boot; SymphonyElixir.ReleaseNode
  # applies it once the service starts distribution. Under bin/symphony, env.sh
  # already set it.
  _cookie = SymphonyElixir.ReleaseCookie.resolve!()
end
