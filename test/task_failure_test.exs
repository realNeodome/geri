defmodule Geri.TaskFailureTest.Observer do
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

defmodule Geri.TaskFailureTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-task-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, :binary.copy("a", 570))
    {:ok, control} = Geri.Control.start_link()

    opts = [
      from: "test@example.com",
      newsgroups: ["test"],
      upload_key: "task-key",
      control: control
    ]

    {:ok, job} = Geri.JobState.start_link("task-key", [path], opts)
    Process.unlink(control)
    Process.unlink(job)
    {:ok, stream} = Geri.Encoder.Base64.stream_file(path, 57)

    items =
      Enum.map(stream, fn part ->
        part = Map.merge(part, %{file_number: 1, file_total: 1, offset: (part.part - 1) * 57})
        {:ok, article} = Geri.Article.build(part, opts)

        part
        |> Map.delete(:body)
        |> Map.merge(%{path: path, part_total: part.total, message_id: article.message_id})
      end)

    on_exit(fn ->
      if Process.alive?(job), do: GenServer.stop(job)
      if Process.alive?(control), do: GenServer.stop(control)
      File.rm_rf!(dir)
    end)

    %{
      path: path,
      nzb: Path.join(dir, "upload.nzb"),
      control: control,
      job: job,
      opts: opts,
      items: items
    }
  end

  for actor <- [:producer, :worker] do
    test "a killed posting #{actor} returns the first failure and stops its peers", c do
      with_upload(c, fn upload, control, context, server ->
        target = if unquote(actor) == :producer, do: context.producer, else: hd(context.workers)
        supervisor = task_supervisor(target)
        send(server.pid, :expect_close)
        Process.exit(target, :kill)
        wait_until(fn -> Geri.Control.mode(control) == :cancelled end)

        if unquote(actor) == :worker do
          # A second crash during shutdown must not replace the first one.
          other = Enum.at(context.workers, 1)
          assert Process.alive?(other)
          Process.exit(other, :kill)
        else
          send(control, :cancel_timeout)
        end

        expected = if unquote(actor) == :producer, do: :producer, else: {:worker, 1}

        assert {:error, {:upload_failed, {:task_exited, :posting, ^expected, :killed}, details}} =
                 Task.await(upload, 2_000)

        assert_upload_cleanup(c, control, context, supervisor, details)
        assert :ok = Task.await(server, 2_000)
      end)
    end
  end

  test "a posting worker exception retains its exception and stack trace", c do
    with_upload(c, fn upload, control, context, server ->
      supervisor = task_supervisor(hd(context.workers))
      # Model a producer bug without introducing a production fault-injection API.
      :sys.replace_state(context.queue, fn state ->
        %{state | ready: :queue.in_r(:invalid_article, state.ready)}
      end)

      send(server.pid, :complete_one)
      wait_until(fn -> Geri.Control.mode(control) == :cancelled end)
      send(control, :cancel_timeout)

      assert {:error,
              {:upload_failed, {:task_exited, :posting, {:worker, worker}, {reason, stack}},
               details}} =
               Task.await(upload, 2_000)

      assert worker in [1, 2]
      assert %FunctionClauseError{} = Exception.normalize(:error, reason, stack)
      assert Enum.any?(stack, &match?({Geri, :posting_item, _, _}, &1))
      assert_upload_cleanup(c, control, context, supervisor, details)
      assert :ok = Task.await(server, 2_000)
    end)
  end

  for actor <- [:producer, :worker] do
    test "a killed repair #{actor} releases its pool without cancelling posting", c do
      with_repair(c, fn repair, queue, posting_queue, server ->
        [{from, _article}] = :queue.to_list(:sys.get_state(queue).producers)
        {producer, _tag} = from
        workers = Map.keys(:sys.get_state(c.control).actors)
        assert length(workers) == 2
        target = if unquote(actor) == :producer, do: producer, else: hd(workers)
        supervisor = task_supervisor(target)
        Process.exit(target, :kill)

        assert {:error, {:task_exited, :repair, failed_actor, :killed}} =
                 Task.await(repair, 2_000)

        if unquote(actor) == :producer do
          assert failed_actor == :producer
        else
          assert {:worker, worker} = failed_actor
          assert worker in [1, 2]
        end

        assert Geri.Control.mode(c.control) == :running
        assert {:ok, :posting_work} = Geri.Queue.next(posting_queue)
        refute Process.alive?(producer)
        refute Process.alive?(supervisor)
        Enum.each(workers, &refute(Process.alive?(&1)))
        refute Process.alive?(queue)
        assert :ok = Task.await(server, 2_000)
      end)
    end
  end

  test "a repair producer exception retains its original cause", c do
    broken = Map.delete(hd(c.items), :path)

    assert {:error, {:task_exited, :repair, :producer, {reason, stack}}} =
             Geri.repair([broken], c.job, [repair_connections: 2, control: c.control], c.opts)

    assert %KeyError{key: :path} = Exception.normalize(:error, reason, stack)
    assert Enum.any?(stack, &match?({Geri, _, _, _}, &1))
    assert Geri.Control.mode(c.control) == :running
    wait_until(fn -> :sys.get_state(c.control).queues == [] end)
  end

  test "cleanup of an already-stopped repair queue does not hide the worker failure", c do
    {listener, port} = listener()

    server =
      Task.async(fn ->
        socket = accept_post(listener)
        complete_one(socket)
        expect_close(socket)
      end)

    owner = self()

    repair =
      Task.async(fn ->
        Geri.repair_session([hd(c.items)], c.job, repair_opts(c, port, 1), c.opts, owner)
      end)

    try do
      assert_receive {:repair_finished, pool, 1, _producer}, 2_000
      assert pool == repair.pid
      [queue] = :sys.get_state(c.control).queues
      # The idle worker's outstanding Queue.next/1 call now exits. Its crash
      # must survive the subsequent attempt to stop this same, dead queue.
      GenServer.stop(queue)

      assert {:error,
              {:task_exited, :repair, {:worker, 1},
               {:normal, {GenServer, :call, [^queue, :next, :infinity]}}}} =
               Task.await(repair, 2_000)

      assert Geri.Control.mode(c.control) == :running
      assert :ok = Task.await(server, 2_000)
    after
      Task.shutdown(repair, :brutal_kill)
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp with_upload(c, run) do
    {listener, port} = listener()
    server = stalled_server(listener)
    observer = {Geri.TaskFailureTest.Observer, make_ref()}
    :ok = :gen_event.add_handler(:erl_signal_server, observer, self())

    upload =
      Task.async(fn ->
        Geri.upload(c.path,
          host: "127.0.0.1",
          port: port,
          tls: :none,
          auth_file: false,
          from: "test@example.com",
          newsgroups: ["test"],
          connections: 2,
          part_size: 57,
          encoding: :base64,
          nzb: c.nzb,
          signal_handler: observer
        )
      end)

    try do
      assert_receive {:upload_control, control} when is_pid(control), 2_000
      wait_until(fn -> Geri.Control.context(control)[:workers] != nil end)
      context = Geri.Control.context(control)
      assert_receive {:posts_ready, pid}, 2_000
      assert pid == server.pid
      wait_until(fn -> not :queue.is_empty(:sys.get_state(context.queue).producers) end)
      run.(upload, control, context, server)
    after
      Task.shutdown(upload, :brutal_kill)
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
      :gen_event.delete_handler(:erl_signal_server, observer, [])
    end
  end

  defp with_repair(c, run) do
    {listener, port} = listener()
    server = stalled_server(listener)
    {:ok, posting_queue} = Geri.Queue.start_link(1)
    :ok = Geri.Control.register_queue(c.control, posting_queue)
    :ok = Geri.Queue.push(posting_queue, :posting_work)

    repair =
      Task.async(fn ->
        Geri.repair(c.items, c.job, repair_opts(c, port, 2), c.opts)
      end)

    try do
      assert_receive {:posts_ready, pid}, 2_000
      assert pid == server.pid
      [queue] = :sys.get_state(c.control).queues -- [posting_queue]
      wait_until(fn -> not :queue.is_empty(:sys.get_state(queue).producers) end)
      send(server.pid, :expect_close)
      run.(repair, queue, posting_queue, server)
    after
      Task.shutdown(repair, :brutal_kill)
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
      GenServer.stop(posting_queue)
    end
  end

  defp assert_upload_cleanup(c, control, context, supervisor, details) do
    assert is_binary(details.upload_key)
    assert File.exists?(c.nzb <> ".part")
    refute File.exists?(c.nzb)

    Enum.each(
      [context.producer, supervisor, context.queue, context.job, control | context.workers],
      fn pid ->
        refute Process.alive?(pid)
      end
    )
  end

  defp task_supervisor(pid) do
    {:links, links} = Process.info(pid, :links)
    [supervisor] = Enum.filter(links, &is_pid/1)
    supervisor
  end

  defp repair_opts(c, port, connections),
    do: [
      host: "127.0.0.1",
      port: port,
      tls: :none,
      repair_connections: connections,
      control: c.control
    ]

  defp listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp stalled_server(listener) do
    parent = self()

    Task.async(fn ->
      sockets = for _ <- 1..2, do: accept_post(listener)
      send(parent, {:posts_ready, self()})

      receive do
        :complete_one -> complete_one(hd(sockets))
        :expect_close -> :ok
      end

      Enum.each(sockets, &expect_close/1)
      :ok
    end)
  end

  defp accept_post(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    :ok = :gen_tcp.send(socket, "200 ready\r\n")
    assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    socket
  end

  defp complete_one(socket) do
    :ok = :gen_tcp.send(socket, "340 send article\r\n")
    receive_article(socket)
    :ok = :gen_tcp.send(socket, "240 received\r\n")
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> receive_article(socket)
    end
  end

  defp expect_close(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, "QUIT\r\n"} -> :gen_tcp.close(socket)
      {:error, reason} when reason in [:closed, :enotconn, :econnreset] -> :ok
    end
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
