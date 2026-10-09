defmodule Geri.Inspection do
  def run(control) do
    :ok = Geri.Control.await_idle(control)
    {:ok, _} = Application.ensure_all_started(:iex)
    context = Geri.Control.context(control)
    leader = Process.group_leader()
    device = spawn_link(fn -> device_loop(leader, false, %{}) end)
    Process.group_leader(self(), device)

    resume = fn ->
      send(device, {:finish, self()})
      receive do :finished -> :ok end
    end

    binding = [
      job: context.job, queue: context.queue, checker: context.checker,
      workers: Map.get(context, :workers, []), producer: Map.get(context, :producer),
      control: control, opts: context.opts, resume: resume
    ]

    try do
      IO.puts("Upload paused. Available: job, queue, checker, workers, producer, control, opts")
      IO.puts("Type resume.() to return to the TUI and continue. Use this instead of Ctrl-D to keep terminal input available.")
      IEx.Server.run(binding: binding, prefix: "geri", on_eof: :stop_evaluator, register: false)
    after
      Process.group_leader(self(), leader)
      Process.unlink(device)
      Process.exit(device, :shutdown)
    end
  end

  # Returning EOF on the next input request ends IEx through its public API.
  # Output still goes to the real terminal, including the result of resume.().
  defp device_loop(leader, finished, pending) do
    receive do
      {:finish, from} ->
        send(from, :finished)
        device_loop(leader, true, pending)

      {:io_request, from, reply_as, request} ->
        if finished and input_request?(request) do
          send(from, {:io_reply, reply_as, :eof})
          device_loop(leader, finished, pending)
        else
          ref = make_ref()
          send(leader, {:io_request, self(), ref, request})
          device_loop(leader, finished, Map.put(pending, ref, {from, reply_as}))
        end

      {:io_reply, ref, reply} ->
        {{from, reply_as}, pending} = Map.pop(pending, ref)
        send(from, {:io_reply, reply_as, reply})
        device_loop(leader, finished, pending)
    end
  end

  defp input_request?(request) when is_tuple(request), do: elem(request, 0) in [:get_line, :get_chars, :get_until, :get_password]
  defp input_request?(_request), do: false
end
