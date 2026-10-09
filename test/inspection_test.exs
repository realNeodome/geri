defmodule Geri.InspectionTest do
  use ExUnit.Case, async: false

  test "IEx can reopen on the same input device after resume.()" do
    {:ok, control} = Geri.Control.start_link()
    observer = self()
    Geri.Control.put_context(control, %{
      job: observer, queue: observer, checker: nil, workers: [],
      opts: [observer: observer]
    })
    Geri.Control.pause(control)
    input = Enum.map_join(1..2, fn session ->
      "send(opts[:observer], {:inspected, #{session}, job, queue})\nresume.()\n"
    end) <> "send(opts[:observer], :read_after_resume)\n"
    {:ok, device} = StringIO.open(input, capture_prompt: true)

    task = Task.async(fn ->
      Process.group_leader(self(), device)
      Enum.map(1..2, fn _ -> Geri.Inspection.run(control) end)
    end)

    try do
      case Task.yield(task, 5_000) do
        {:ok, result} -> assert result == [:ok, :ok]
        nil ->
          {_remaining, output} = StringIO.contents(device)
          stack = Process.info(task.pid, :current_stacktrace)
          flunk("IEx inspection stalled. Output:\n#{output}\nStack: #{inspect(stack)}")
      end

      {_remaining, output} = StringIO.contents(device)
      assert_receive {:inspected, 1, ^observer, ^observer}, 1_000, output
      assert_receive {:inspected, 2, ^observer, ^observer}, 1_000, output
      refute_received :read_after_resume
      assert Process.alive?(control)
      # The terminal manager, rather than the IEx evaluator, resumes work.
      assert Geri.Control.mode(control) == :paused
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      StringIO.close(device)
    end
  end
end
