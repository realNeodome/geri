defmodule Geri.CheckerFailureTest.Observer do
  @behaviour :gen_event
  def init(parent), do: {:ok, parent}

  def handle_call({:attach, control}, parent) do
    send(parent, {:upload_control, control})
    {:ok, :ok, parent}
  end

  def handle_event(_event, parent), do: {:ok, parent}
  def handle_info(_message, parent), do: {:ok, parent}
  def terminate(_reason, _parent), do: :ok
  def code_change(_old, parent, _extra), do: {:ok, parent}
end

defmodule Geri.CheckerFailureTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(System.tmp_dir!(), "geri-checker-failure-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    paths =
      for number <- 1..3 do
        path = Path.join(dir, "#{number}.bin")
        File.write!(path, "file #{number}")
        path
      end

    {:ok, control} = Geri.Control.start_link()

    opts = [
      from: "test@example.com",
      newsgroups: ["test"],
      upload_key: "checker-key",
      control: control
    ]

    {:ok, job} = Geri.JobState.start_link("checker-key", paths, opts)
    Process.unlink(control)
    Process.unlink(job)

    items =
      for {path, number} <- Enum.with_index(paths, 1) do
        {:ok, stream} = Geri.Encoder.Base64.stream_file(path, 57)
        [part] = Enum.to_list(stream)
        part = Map.merge(part, %{file_number: number, file_total: 3, offset: 0})
        {:ok, article} = Geri.Article.build(part, opts)

        part
        |> Map.delete(:body)
        |> Map.merge(%{path: path, part_total: 1, message_id: article.message_id})
      end

    on_exit(fn ->
      if Process.alive?(job), do: GenServer.stop(job)
      if Process.alive?(control), do: GenServer.stop(control)
      File.rm_rf!(dir)
    end)

    %{job: job, control: control, paths: paths, items: items, nzb: Path.join(dir, "upload.nzb")}
  end

  test "an idle worker crash classifies queued and future checks and ignores late results", c do
    with_checker(c, [connections: 2], fn checker ->
      [first, second, future] = c.items
      for item <- [first, second], do: Geri.Checker.enqueue(checker, item)
      wait_until(fn -> MapSet.size(:sys.get_state(checker).idle) == 2 end)
      workers = :sys.get_state(checker).workers
      [{worker, id} | _] = Map.to_list(workers)
      Process.exit(worker, :kill)
      wait_until(fn -> :sys.get_state(checker).check_error != nil end)
      assert :ok = Geri.Checker.enqueue(checker, future)
      send(checker, {:checker_ready, worker, id})
      send(checker, {:checker_result, worker, id, first, :present})
      send(checker, {:EXIT, worker, :secondary_failure})

      assert {:error,
              {:verification_failed, summary,
               [{:task_exited, :checking, {:worker, ^id}, :killed}]}} =
               Geri.Checker.finish(checker)

      assert summary.inconclusive == 3
      assert summary.confirmed == 0
      assert summary.missing == 0
      assert Enum.all?(summary.unresolved, &(&1.reason == :checker_stopped))
      assert Geri.Control.mode(c.control) == :running
      state = :sys.get_state(checker)
      assert state.workers == %{}
      assert state.inflight == %{}
      assert state.timer == nil
      assert state.files == %{}
      assert state.repairs == []
      assert :gb_trees.is_empty(state.queue)
      wait_until(fn -> Enum.all?(Map.keys(workers), &(not Process.alive?(&1))) end)
    end)
  end

  test "a worker crash during STAT releases finish waiters and the socket", c do
    {listener, port} = listener()
    server = stalled_check_server(listener)

    try do
      with_checker(c, [connections: 1, host: "127.0.0.1", port: port, tls: :none], fn checker ->
        for item <- Enum.take(c.items, 2), do: Geri.Checker.enqueue(checker, item)
        advance_checks(checker)
        assert_receive {:stat_waiting, server_pid}, 2_000
        assert server_pid == server.pid
        state = :sys.get_state(checker)
        [worker] = Map.keys(state.inflight)
        assert :gb_trees.size(state.queue) == 1
        finish = Task.async(fn -> Geri.Checker.finish(checker) end)
        assert Task.yield(finish, 20) == nil
        Process.exit(worker, :kill)

        assert {:error,
                {:verification_failed, summary,
                 [{:task_exited, :checking, {:worker, 1}, :killed}]}} = Task.await(finish, 2_000)

        assert summary.inconclusive == 2
        assert summary.missing == 0
        assert :ok = Task.await(server, 2_000)
        assert Process.alive?(checker)
        assert Geri.Control.mode(c.control) == :running
      end)
    after
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  test "a real checker exception preserves its original reason and stack trace", c do
    # Missing internal connection options model a worker bug, without adding a
    # fault-injection switch to the production API.
    with_checker(c, [connections: 1], fn checker ->
      Geri.Checker.enqueue(checker, hd(c.items))
      advance_checks(checker)
      wait_until(fn -> :sys.get_state(checker).check_error != nil end)

      assert {:error,
              {:verification_failed, summary,
               [{:task_exited, :checking, {:worker, 1}, {reason, stack}}]}} =
               Geri.Checker.finish(checker)

      assert %KeyError{key: :host} = Exception.normalize(:error, reason, stack)
      assert Enum.any?(stack, &match?({Geri.NNTP, :connect, _, _}, &1))
      assert summary.inconclusive == 1
      assert Geri.Control.mode(c.control) == :running
    end)
  end

  test "the checker and its workers still stop when their owner dies", c do
    parent = self()

    owner =
      Task.async(fn ->
        {:ok, checker} = Geri.Checker.start_link(c.job, connections: 2, control: c.control)
        send(parent, {:owned_checker, checker, Map.keys(:sys.get_state(checker).workers)})

        receive do
          :stop -> :ok
        end
      end)

    Process.unlink(owner.pid)

    try do
      assert_receive {:owned_checker, checker, workers}, 2_000
      Process.exit(owner.pid, :kill)
      assert_receive {:DOWN, ref, :process, pid, :killed}, 2_000
      assert ref == owner.ref
      assert pid == owner.pid
      wait_until(fn -> not Process.alive?(checker) end)
      wait_until(fn -> Enum.all?(workers, &(not Process.alive?(&1))) end)
    after
      if Process.alive?(owner.pid), do: Task.shutdown(owner, :brutal_kill)
    end
  end

  test "posting continues after a checker crash and retains a complete NZB", c do
    {posting_listener, posting_port} = listener()
    {check_listener, check_port} = listener()
    parent = self()

    posting_server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(posting_listener, 2_000)
        :ok = :gen_tcp.send(socket, "200 ready\r\n")

        for number <- 1..3 do
          assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)

          if number == 2 do
            send(parent, :second_post_waiting)

            receive do
              :continue -> :ok
            end
          end

          :ok = :gen_tcp.send(socket, "340 send article\r\n")
          receive_article(socket)
          :ok = :gen_tcp.send(socket, "240 received\r\n")
        end

        expect_close(socket)
      end)

    check_server = stalled_check_server(check_listener)
    observer = {Geri.CheckerFailureTest.Observer, make_ref()}
    :ok = :gen_event.add_handler(:erl_signal_server, observer, self())

    upload =
      Task.async(fn ->
        Geri.upload(c.paths,
          host: "127.0.0.1",
          port: posting_port,
          tls: :none,
          auth_file: false,
          check_host: "127.0.0.1",
          check_port: check_port,
          check_tls: :none,
          connections: 1,
          check_connections: 1,
          repair_connections: 1,
          from: "test@example.com",
          newsgroups: ["test"],
          nzb: c.nzb,
          encoding: :base64,
          part_size: 57,
          signal_handler: observer
        )
      end)

    try do
      assert_receive {:upload_control, control} when is_pid(control), 2_000
      assert_receive :second_post_waiting, 2_000
      checker = Geri.Control.context(control).checker
      advance_checks(checker)
      assert_receive {:stat_waiting, server_pid}, 2_000
      assert server_pid == check_server.pid
      [worker] = Map.keys(:sys.get_state(checker).inflight)
      Process.exit(worker, :kill)
      wait_until(fn -> :sys.get_state(checker).check_error != nil end)
      assert Geri.Control.mode(control) == :running
      assert Process.alive?(upload.pid)
      send(posting_server.pid, :continue)

      assert {:error,
              {:verification_failed, summary, [{:task_exited, :checking, {:worker, 1}, :killed}]}} =
               Task.await(upload, 2_000)

      assert summary.inconclusive == 3
      assert summary.missing == 0
      assert summary.repaired == 0
      assert is_binary(summary.upload_key)
      assert summary.nzb.path == c.nzb
      xml = File.read!(c.nzb)
      assert xml =~ "</nzb>"
      assert length(Regex.scan(~r/<file /, xml)) == 3
      refute File.exists?(c.nzb <> ".part")
      assert :ok = Task.await(posting_server, 2_000)
      assert :ok = Task.await(check_server, 2_000)
      assert {:error, :timeout} = :gen_tcp.accept(check_listener, 20)
    after
      Task.shutdown(upload, :brutal_kill)
      Enum.each([posting_server, check_server], &Task.shutdown(&1, :brutal_kill))
      Enum.each([posting_listener, check_listener], &:gen_tcp.close/1)
      :gen_event.delete_handler(:erl_signal_server, observer, [])
    end
  end

  defp with_checker(c, opts, run) do
    {:ok, checker} = Geri.Checker.start_link(c.job, Keyword.put(opts, :control, c.control))

    try do
      run.(checker)
    after
      if Process.alive?(checker), do: GenServer.stop(checker)
    end
  end

  defp listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp stalled_check_server(listener) do
    parent = self()

    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2_000)
      :ok = :gen_tcp.send(socket, "200 ready\r\n")
      assert {:ok, "STAT " <> _} = :gen_tcp.recv(socket, 0, 2_000)
      send(parent, {:stat_waiting, self()})
      expect_close(socket)
    end)
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _} -> receive_article(socket)
    end
  end

  defp expect_close(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, "QUIT\r\n"} -> :gen_tcp.close(socket)
      {:error, reason} when reason in [:closed, :enotconn, :econnreset] -> :ok
    end
  end

  defp advance_checks(checker) do
    wait_until(fn -> not :gb_trees.is_empty(:sys.get_state(checker).queue) end)

    :sys.replace_state(checker, fn state ->
      if state.timer, do: Process.cancel_timer(state.timer)
      now = System.monotonic_time(:millisecond) - 1

      entries =
        for {{_due, sequence}, item} <- :gb_trees.to_list(state.queue),
            do: {{now, sequence}, item}

      %{state | queue: :gb_trees.from_orddict(Enum.sort(entries)), timer: nil}
    end)

    send(checker, :dispatch)
  end

  defp wait_until(fun), do: wait_until(fun, System.monotonic_time(:millisecond) + 2_000)

  defp wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(2)
      wait_until(fun, deadline)
    end
  end
end
