defmodule SymphonyElixir.DescriptionLock do
  @moduledoc """
  One writer of a ticket's Linear description at a time.

  Every writer reads the description, changes its own part and writes the whole text back: the
  projector (`SymphonyElixir.Pauses.Projector`: the Decisions section, a groomed ticket's ask, plan
  and checks, the summary block's changelog) and a run's summary tool
  (`SymphonyElixir.AgentTools.Linear.update_issue_summary/3`). Two of them at once would each write
  over what the other just wrote, and they meet often: the projector writes each time a check is
  proved, which is when a run also updates its summary. `locked/2` runs one read-and-write at a
  time per issue, on this node; a second caller waits for the first. A write must not take the
  lock again inside itself: the inner one's end would release the outer.
  """

  @doc "Runs `write`, which reads and writes the description of the issue `issue_id`, while no other does."
  @spec locked(String.t(), (-> result)) :: result when result: term()
  def locked(issue_id, write) when is_binary(issue_id) and is_function(write, 0) do
    :global.trans({{__MODULE__, issue_id}, self()}, write, [node()], :infinity)
  end
end
