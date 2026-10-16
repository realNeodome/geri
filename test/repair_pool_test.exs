defmodule Geri.RepairPoolTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-repair-pool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    paths =
      for number <- 1..2 do
        path = Path.join(dir, "#{number}.bin")
        File.write!(path, "file #{number}")
        path
      end

    {:ok, control} = Geri.Control.start_link()

    opts = [
      from: "test@example.com",
      newsgroups: ["test"],
      upload_key: "pool-key",
      control: control
    ]

    {:ok, job} = Geri.JobState.start_link("pool-key", paths, opts)
    Process.unlink(control)
    Process.unlink(job)

    items =
      for {path, number} <- Enum.with_index(paths, 1) do
        {:ok, stream} = Geri.Encoder.Base64.stream_file(path, 57)
        [part] = Enum.to_list(stream)
        part = Map.merge(part, %{file_number: number, file_total: 2, offset: 0})
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

    %{job: job, control: control, opts: opts, items: items}
  end

  test "a queued file reuses the busy repair pool and finish waits for both files", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      [first, second] = c.items
      check_missing(checker, first)
      assert_receive {:article, ^server_pid}, 2_000
      pool = :sys.get_state(checker).repair_pid
      [queue] = :sys.get_state(c.control).queues

      check_missing(checker, second)
      assert length(:sys.get_state(checker).repairs) == 1
      finish = Task.async(fn -> Geri.Checker.finish(checker) end)
      assert Task.yield(finish, 20) == nil
      assert Process.alive?(pool)
      send(server_pid, {:respond, "240 received\r\n"})

      assert_receive {:article, ^server_pid}, 2_000
      assert :sys.get_state(checker).repair_pid == pool
      assert :sys.get_state(c.control).queues == [queue]
      assert Task.yield(finish, 20) == nil
      send(server_pid, {:respond, "240 received\r\n"})
      assert :ok = Task.await(finish, 2_000)
      assert :ok = Task.await(server, 2_000)
      assert Geri.JobState.verification(c.job).repaired == 2
      refute Process.alive?(pool)
      wait_until(fn -> :sys.get_state(c.control).queues == [] end)
    end)
  end

  test "an idle repair pool waits for future checks and reuses its connection", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      [first, second] = c.items
      check_missing(checker, first)
      assert_receive {:article, ^server_pid}, 2_000
      send(server_pid, {:respond, "240 received\r\n"})
      wait_until(fn -> not :sys.get_state(checker).repairing end)
      pool = :sys.get_state(checker).repair_pid
      assert Process.alive?(pool)
      assert Geri.JobState.verification(c.job).repaired == 1
      assert Process.alive?(server_pid)

      check_missing(checker, second)
      assert_receive {:article, ^server_pid}, 2_000
      assert :sys.get_state(checker).repair_pid == pool
      send(server_pid, {:respond, "240 received\r\n"})
      assert :ok = Geri.Checker.finish(checker)
      assert :ok = Task.await(server, 2_000)
      assert Geri.JobState.verification(c.job).repaired == 2
    end)
  end

  test "a rejected article completes its batch without blocking later repairs", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      [first, second] = c.items
      check_missing(checker, first)
      assert_receive {:article, ^server_pid}, 2_000
      send(server_pid, {:respond, "441 rejected\r\n"})
      wait_until(fn -> not :sys.get_state(checker).repairing end)
      pool = :sys.get_state(checker).repair_pid
      check_missing(checker, second)
      assert_receive {:article, ^server_pid}, 2_000
      assert :sys.get_state(checker).repair_pid == pool
      send(server_pid, {:respond, "240 received\r\n"})
      assert {:error, _} = Geri.Checker.finish(checker)
      assert :ok = Task.await(server, 2_000)
      summary = Geri.JobState.verification(c.job)
      assert summary.repaired == 1
      assert summary.repair_failed == 1
    end)
  end

  test "a fatal preparation failure releases its queue and allows a later batch", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      [first, second] = c.items
      File.rm!(first.path)
      check_missing(checker, first)
      wait_until(fn -> :sys.get_state(checker).repair_errors != [] end)
      wait_until(fn -> :sys.get_state(c.control).queues == [] end)
      assert Geri.Control.mode(c.control) == :running
      check_missing(checker, second)
      assert_receive {:article, ^server_pid}, 2_000
      send(server_pid, {:respond, "240 received\r\n"})
      assert {:error, _} = Geri.Checker.finish(checker)
      assert :ok = Task.await(server, 2_000)
      assert Geri.JobState.verification(c.job).repaired == 1
    end)
  end

  for phase <- [:between_batches, :awaiting_result] do
    test "cancellation wakes the repair producer #{phase}", c do
      with_checker(c, fn checker, server ->
        server_pid = server.pid
        check_missing(checker, hd(c.items))
        assert_receive {:article, ^server_pid}, 2_000

        if unquote(phase) == :between_batches do
          send(server_pid, {:respond, "240 received\r\n"})
          wait_until(fn -> not :sys.get_state(checker).repairing end)
        end

        pool = :sys.get_state(checker).repair_pid
        Geri.Control.cancel(c.control)

        if unquote(phase) == :awaiting_result do
          # Exercise the normal cancellation deadline without a ten-second test wait.
          send(c.control, :cancel_timeout)
          send(server_pid, {:respond, "240 received\r\n"})
        end

        assert {:error, :cancelled} = Geri.Checker.finish(checker)
        wait_until(fn -> not Process.alive?(pool) end)
        wait_until(fn -> :sys.get_state(c.control).queues == [] end)
      end)
    end
  end

  test "a file is not finished until every repair article has a result", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      items = split_first_file(c, 2)
      enqueue_missing(checker, items)
      assert_receive {:article, ^server_pid}, 2_000
      finish = Task.async(fn -> Geri.Checker.finish(checker) end)
      send(server_pid, {:respond, "240 received\r\n"})
      assert_receive {:article, ^server_pid}, 2_000
      assert Geri.JobState.verification(c.job).repaired == 1
      assert Task.yield(finish, 20) == nil
      send(server_pid, {:respond, "240 received\r\n"})
      assert :ok = Task.await(finish, 2_000)
      assert :ok = Task.await(server, 2_000)
      assert Geri.JobState.verification(c.job).repaired == 2
    end)
  end

  test "cancellation wakes a producer blocked by a full prepared-article queue", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      enqueue_missing(checker, split_first_file(c, 6))
      assert_receive {:article, ^server_pid}, 2_000
      pool = :sys.get_state(checker).repair_pid
      [queue] = :sys.get_state(c.control).queues
      wait_until(fn -> not :queue.is_empty(:sys.get_state(queue).producers) end)
      Geri.Control.cancel(c.control)
      send(c.control, :cancel_timeout)
      send(server_pid, {:respond, "240 received\r\n"})
      assert {:error, :cancelled} = Geri.Checker.finish(checker)
      wait_until(fn -> not Process.alive?(pool) end)
      wait_until(fn -> :sys.get_state(c.control).queues == [] end)
    end)
  end

  test "an idle repair worker crash becomes a verification failure without killing the checker", c do
    with_checker(c, fn checker, server ->
      server_pid = server.pid
      check_missing(checker, hd(c.items))
      assert_receive {:article, ^server_pid}, 2_000
      send(server_pid, {:respond, "240 received\r\n"})
      wait_until(fn -> not :sys.get_state(checker).repairing end)
      [queue] = :sys.get_state(c.control).queues
      wait_until(fn -> not :queue.is_empty(:sys.get_state(queue).consumers) end)
      [{worker, _tag}] = :queue.to_list(:sys.get_state(queue).consumers)
      Process.exit(worker, :kill)
      wait_until(fn -> :sys.get_state(checker).repair_errors != [] end)
      assert Process.alive?(checker)
      assert Geri.Control.mode(c.control) == :running
      assert {:error, {:verification_failed, summary,
               [{:task_exited, :repair, {:worker, 1}, :killed}]}} = Geri.Checker.finish(checker)
      assert summary.repaired == 1
      assert :ok = Task.await(server, 2_000)
    end)
  end

  test "verification without missing articles never creates a repair pool", c do
    with_checker(
      c,
      fn checker, _server ->
        for item <- c.items, do: Geri.Checker.enqueue(checker, item)
        advance_checks(checker)
        wait_until(fn -> :sys.get_state(checker).inflight == 0 end)
        assert :ok = Geri.Checker.finish(checker)
        assert :sys.get_state(checker).repair_pid == nil
        assert :sys.get_state(c.control).queues == []
        assert Geri.JobState.verification(c.job).confirmed == 2
      end,
      "223 present\r\n"
    )
  end

  defp with_checker(c, run, response \\ "430 missing\r\n") do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        :ok = :gen_tcp.send(socket, "200 ready\r\n")

        checks =
          Task.async(fn ->
            receive do
              {:socket, socket} -> serve_checks(socket, response)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, checks.pid)
        send(checks.pid, {:socket, socket})

        try do
          {:ok, repair} = :gen_tcp.accept(listener, 5_000)
          :ok = :gen_tcp.send(repair, "200 ready\r\n")
          serve_repairs(repair, parent)
        after
          Task.shutdown(checks, :brutal_kill)
        end
      end)

    repair_opts = [
      host: "127.0.0.1",
      port: port,
      tls: :none,
      repair_connections: 1,
      control: c.control
    ]

    opts =
      Keyword.merge(repair_opts, connections: 1, repair_opts: repair_opts, article_opts: c.opts)

    {:ok, checker} = Geri.Checker.start_link(c.job, opts)
    Process.unlink(checker)

    try do
      run.(checker, server)
    after
      if Process.alive?(checker), do: GenServer.stop(checker)
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp serve_checks(socket, response) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, "STAT " <> _} ->
        :ok = :gen_tcp.send(socket, response)
        serve_checks(socket, response)

      {:ok, "QUIT\r\n"} ->
        :gen_tcp.close(socket)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve_repairs(socket, parent) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, "STAT " <> _} ->
        :ok = :gen_tcp.send(socket, "430 missing\r\n")
        serve_repairs(socket, parent)

      {:ok, "POST\r\n"} ->
        :ok = :gen_tcp.send(socket, "340 send article\r\n")
        receive_article(socket)
        send(parent, {:article, self()})

        receive do
          {:respond, response} -> :gen_tcp.send(socket, response)
        end

        serve_repairs(socket, parent)

      {:ok, "QUIT\r\n"} ->
        :gen_tcp.close(socket)

      {:error, reason} when reason in [:closed, :econnreset, :enotconn] ->
        :ok
    end
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _} -> receive_article(socket)
    end
  end

  defp split_first_file(c, count) do
    first = hd(c.items)
    size = 57
    File.write!(first.path, :binary.copy("x", size * count))
    {:ok, stream} = Geri.Encoder.Base64.stream_file(first.path, size)

    Enum.map(stream, fn part ->
      part = Map.merge(part, %{file_number: 1, file_total: 2, offset: (part.part - 1) * size})
      {:ok, article} = Geri.Article.build(part, c.opts)

      part
      |> Map.delete(:body)
      |> Map.merge(%{path: first.path, part_total: part.total, message_id: article.message_id})
    end)
  end

  defp check_missing(checker, item), do: enqueue_missing(checker, [item])

  defp enqueue_missing(checker, items) do
    for item <- items, do: Geri.Checker.enqueue(checker, item)

    for _ <- 1..3 do
      advance_checks(checker)
      wait_until(fn -> :sys.get_state(checker).inflight == 0 end)
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

    wait_until(fn ->
      :gb_trees.is_empty(:sys.get_state(checker).queue) or :sys.get_state(checker).timer != nil
    end)
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
