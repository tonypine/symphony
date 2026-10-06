defmodule SymphonyElixir.OpenRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OpenRouter

  @qa_root %{"SYMPHONY_BAR_QA_ROOT" => "/tmp/qa"}

  defp base_url(env), do: OpenRouter.base_url(env)

  test "a normal run always talks to openrouter.ai, whatever the environment says" do
    assert OpenRouter.base_url() == "https://openrouter.ai/api"
    assert base_url(%{}) == "https://openrouter.ai/api"
    assert base_url(%{"SYMPHONY_QA_OPENROUTER_URL" => "http://127.0.0.1:4100/api"}) == "https://openrouter.ai/api"
    assert base_url(%{"SYMPHONY_BAR_QA_ROOT" => " \n", "SYMPHONY_QA_OPENROUTER_URL" => "http://127.0.0.1:4100/api"}) == "https://openrouter.ai/api"
    assert base_url(@qa_root) == "https://openrouter.ai/api"
  end

  test "QA mode talks to a loopback stub" do
    assert OpenRouter.qa_url_env() == "SYMPHONY_QA_OPENROUTER_URL"

    for {url, expected} <- [
          {" http://127.0.0.1:4100/api/\n", "http://127.0.0.1:4100/api"},
          {"https://localhost:4100/api", "https://localhost:4100/api"},
          {"http://[::1]:4100/api", "http://[::1]:4100/api"}
        ] do
      assert base_url(Map.put(@qa_root, "SYMPHONY_QA_OPENROUTER_URL", url)) == expected
    end
  end

  test "QA mode ignores a stub URL that would send the key off this machine" do
    for url <- [
          "https://openrouter.example.com/api",
          "http://10.0.0.5:4100/api",
          "http://127.0.0.1.example.com/api",
          "http://user:pass@127.0.0.1:4100/api",
          "http://127.0.0.1:4100/api?next=https://evil.example",
          "http://127.0.0.1:4100/api#fragment",
          "ftp://127.0.0.1/api",
          "127.0.0.1:4100",
          ""
        ] do
      assert base_url(Map.put(@qa_root, "SYMPHONY_QA_OPENROUTER_URL", url)) == "https://openrouter.ai/api", url
    end
  end
end
