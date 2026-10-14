defmodule Geri.FailureReportingTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-result-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, "hello")
    nzb = Path.join(dir, "upload.nzb")
    opts = [from: "test@example.invalid", host: "localhost", newsgroups: ["test"], nzb: nzb]
    {:ok, job} = Geri.JobState.start_link("test-key", [path], opts)
    Process.unlink(job)

    part = %{
      file_number: 1, file_total: 1, file_size: 5, filename: "source.bin",
      encoding: :uuencode, part: 1, total: 1, source_size: 5,
      source_hash: :crypto.hash(:sha256, "hello"), offset: 0,
      subject: "source.bin (1/1)"
    }
    article = %{message_id: "<part@test.invalid>", data: "article\r\n"}
    item = part |> Map.put(:part_total, 1) |> Map.put(:message_id, article.message_id) |> Map.put(:path, path)

    on_exit(fn ->
      if Process.alive?(job) do
        Geri.JobState.abort(job)
        GenServer.stop(job)
      end
      File.rm_rf!(dir)
    end)

    %{job: job, part: part, article: article, item: item, nzb: nzb, dir: dir, opts: opts}
  end

  test "duplicate and late results do not count progress twice", c do
    Geri.JobState.set_checker(c.job, self())
    Geri.JobState.check_present(c.job, c.item, 1)
    Geri.JobState.check_present(c.job, c.item, 1)
    before = Geri.JobState.snapshot(c.job)
    assert :sys.get_state(c.job).ui.checked_bytes == 5
    Geri.JobState.finish_verification_file(c.job, 1)
    Geri.JobState.check_present(c.job, c.item, 1)
    Geri.JobState.check_missing(c.job, c.item, 1)
    Geri.JobState.check_not_found(c.job, c.item, 1)
    Geri.JobState.repair_failed(c.job, c.item, 1, :late)
    assert Geri.JobState.verification(c.job).confirmed == 1
    assert Geri.JobState.failure_info(c.job).unresolved == []
    after_snapshot = Geri.JobState.snapshot(c.job)
    assert after_snapshot.activity == before.activity
    assert :sys.get_state(c.job).ui.checked_bytes == 5
  end

  test "folding repaired and failed parts preserves the public result", c do
    Geri.JobState.check_missing(c.job, c.item, 1)
    Geri.JobState.repair_present(c.job, c.item, 1)
    failed = %{c.item | part: 2}
    Geri.JobState.check_missing(c.job, failed, 1)
    Geri.JobState.repair_failed(c.job, failed, 1, :rejected)
    before = Geri.JobState.result(c.job)
    Geri.JobState.finish_verification_file(c.job, 1)
    assert Geri.JobState.result(c.job) == before
    assert :sys.get_state(c.job).verification.files == %{}
    assert [%{part: 2, reason: :rejected}] = Geri.JobState.failure_info(c.job).unresolved
  end

  for outcome <- [:confirmed, :repaired, :repair_failed] do
    test "checker automatically folds a file after #{outcome}", c do
      assert_checker_folds(c, unquote(outcome))
    end
  end

  test "successful posting and repair preserve the original success result", c do
    assert :ok = Geri.JobState.prepare_part(c.job, c.part, c.article)
    assert :ok = Geri.JobState.complete_part(c.job, c.part, c.article, ["test"], 1)
    Geri.JobState.check_missing(c.job, c.item, 1)
    assert :ok = Geri.JobState.repair_present(c.job, c.item, 1)
    assert :ok = Geri.JobState.result(c.job)
    assert Geri.JobState.failure_info(c.job).unresolved == []
    assert :ok = Geri.JobState.finalize(c.job)
    assert File.read!(c.nzb) =~ "</nzb>"
  end

  test "inconclusive checks preserve a complete NZB and repair details", c do
    Geri.JobState.prepare_part(c.job, c.part, c.article)
    Geri.JobState.complete_part(c.job, c.part, c.article, ["test"], 1)
    Geri.JobState.check_inconclusive(c.job, c.item, 1, :timeout)
    assert :ok = Geri.JobState.finalize(c.job)
    assert {:error, {:verification_inconclusive, details}} = Geri.JobState.result(c.job)
    assert details.upload_key == "test-key"
    assert details.inconclusive == 1
    assert [%{message_id: "<part@test.invalid>", reason: :timeout, path: path}] = details.unresolved
    assert File.exists?(path)
    assert details.nzb.path == c.nzb
    assert File.read!(c.nzb) =~ "part@test.invalid"
    refute File.exists?(c.nzb <> ".part")
  end

  test "repair failure takes precedence over an inconclusive check", c do
    Geri.JobState.check_inconclusive(c.job, c.item, 1, :timeout)
    missing = %{c.item | part: 2, message_id: "<missing@test.invalid>"}
    Geri.JobState.check_missing(c.job, missing, 1)
    Geri.JobState.repair_failed(c.job, missing, 1, :rejected)
    assert {:error, {:verification_failed, details, []}} = Geri.JobState.result(c.job)
    assert details.repair_failed == 1
    assert details.inconclusive == 1
    assert Enum.any?(details.unresolved, &(&1.reason == :rejected))
  end

  test "repair producer and connection errors fail even without per-part failures", c do
    assert {:error, {:verification_failed, _, [:repair_open_failed]}} =
             Geri.JobState.result(c.job, [:repair_open_failed])
  end

  test "failure details retain the producer frontier and unfinished NZB segments", c do
    first = %{c.part | total: 2}
    second = %{first | part: 2}
    Geri.JobState.prepare_part(c.job, first, c.article)
    Geri.JobState.complete_part(c.job, first, c.article, ["test"], 1)
    Geri.JobState.prepare_part(c.job, second, %{c.article | message_id: "<second@test.invalid>"})
    details = Geri.JobState.failure_info(c.job)
    assert details.recovery.files[1].next_part == 3
    assert Map.keys(details.recovery.files[1].unresolved) == [2]
    assert details.nzb.pending_files[1].segments[1].message_id == "part@test.invalid"
    Geri.JobState.abort(c.job)
    assert File.exists?(c.nzb <> ".part")
  end

  test "initialization failure returns a normal error without opening an NZB", c do
    missing = Path.join(c.dir, "missing")
    nzb = Path.join(c.dir, "unused.nzb")
    assert {:error, {:file_stat_failed, ^missing, :enoent}} =
             Geri.JobState.start_link("key", [missing], Keyword.put(c.opts, :nzb, nzb))
    refute File.exists?(nzb <> ".part")
  end

  test "NZB write errors return failure rather than crashing JobState", c do
    state = :sys.get_state(c.job)
    File.close(state.nzb.writer.io)
    Geri.JobState.prepare_part(c.job, c.part, c.article)
    assert {:error, {:nzb_write_failed, {:error, _}}} =
             Geri.JobState.complete_part(c.job, c.part, c.article, ["test"], 1)
    assert Process.alive?(c.job)
    assert map_size(Geri.JobState.failure_info(c.job).nzb.pending_files) == 1
  end

  test "checker finish returns JobState's terminal outcome", c do
    Geri.JobState.check_inconclusive(c.job, c.item, 1, :timeout)
    {:ok, checker} = Geri.Checker.start_link(c.job, connections: 1)
    try do
      assert {:error, {:verification_inconclusive, %{upload_key: "test-key"}}} = Geri.Checker.finish(checker)
    after
      GenServer.stop(checker)
    end
  end

  test "a rejected STARTTLS greeting closes the TCP connection" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        :ok = :gen_tcp.send(socket, "500 posting not allowed\r\n")
        result = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        result
      end)
    {:ok, {_address, port}} = :inet.sockname(listener)

    try do
      assert {:error, {:unexpected_greeting, 500, "posting not allowed"}} =
               Geri.NNTP.connect(host: "127.0.0.1", port: port, tls: :starttls)

      # The client must close its socket, so the server sees EOF rather than
      # waiting out its receive timeout.
      assert {:error, :closed} = Task.await(server, 6_000)
    after
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  test "core upload returns posting failure with the upload key", c do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    opts = c.opts |> Keyword.delete(:nzb) |> Keyword.merge(
      host: "127.0.0.1", port: port, tls: :none, auth_file: false,
      connections: 1, upload_key: "failed-key"
    )
    assert {:error, {:upload_failed, _, %{upload_key: "failed-key"}}} =
             Geri.upload(c.item.path, opts)
  end

  test "CLI process exits with 0, 1, 2, or 130 according to the core result" do
    summary = %{upload_key: "key", confirmed: 0, repaired: 0, missing: 0, repair_failed: 0, inconclusive: 1}
    cli = Path.expand("../lib/geri/cli.ex", __DIR__)

    for {result, expected} <- [
      {{:ok, "key"}, 0},
      {{:error, {:verification_failed, %{summary | repair_failed: 1}, []}}, 1},
      {{:error, {:verification_inconclusive, summary}}, 2},
      {{:error, {:cancelled, %{upload_key: "key"}}}, 130}
    ] do
      code = "defmodule Geri do\n def upload(_, _), do: #{inspect(result)}\nend\n" <>
        "Code.require_file(#{inspect(cli)})\n" <>
        "Geri.CLI.main([\"upload\", \"--host\", \"localhost\", \"--from\", \"test@invalid\", \"--group\", \"test\", \"file.bin\"])"
      {output, status} = System.cmd(System.find_executable("elixir"), ["-e", code], stderr_to_stdout: true)
      assert status == expected, output
    end
  end

  test "cancellation wakes finish while verification is waiting for propagation", c do
    {:ok, control} = Geri.Control.start_link()
    {:ok, checker} = Geri.Checker.start_link(c.job, connections: 1, control: control)
    Geri.Control.put_context(control, %{checker: checker})
    Geri.Checker.enqueue(checker, c.item)
    task = Task.async(fn -> Geri.Checker.finish(checker) end)
    assert Task.yield(task, 20) == nil
    Geri.Control.cancel(control)
    assert {:error, :cancelled} = Task.await(task, 1_000)
    GenServer.stop(checker)
    GenServer.stop(control)
  end

  defp assert_checker_folds(c, outcome) do
    article_opts = Keyword.put(c.opts, :upload_key, "test-key")
    part = Map.put(c.part, :body, Geri.Encoder.UUEncode.encode_part("hello", c.part.filename, 1, 1))
    {:ok, article} = Geri.Article.build(part, article_opts)
    item = %{c.item | message_id: article.message_id}
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    server = Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2_000)
      :ok = :gen_tcp.send(socket, "200 ready\r\n")
      for _ <- 1..if(outcome == :confirmed, do: 1, else: 3) do
        assert {:ok, "STAT " <> _} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, if(outcome == :confirmed, do: "223 present\r\n", else: "430 missing\r\n"))
      end
      if outcome != :confirmed do
        {:ok, repair} = :gen_tcp.accept(listener, 2_000)
        :ok = :gen_tcp.send(repair, "200 ready\r\n")
        assert {:ok, "POST\r\n"} = :gen_tcp.recv(repair, 0, 2_000)
        send(parent, {:repair_waiting, self()})
        receive do :continue -> :ok after 2_000 -> flunk("repair was not released") end
        if outcome == :repaired do
          :ok = :gen_tcp.send(repair, "340 send article\r\n")
          drain_article(repair)
          :ok = :gen_tcp.send(repair, "240 accepted\r\n")
        else
          :ok = :gen_tcp.send(repair, "440 posting denied\r\n")
        end
        :gen_tcp.close(repair)
      end
      receive do :stop -> :ok after 2_000 -> flunk("checker did not finish") end
      :gen_tcp.close(socket)
    end)
    opts = [host: "127.0.0.1", port: port, tls: :none, connections: 1,
      repair_opts: [host: "127.0.0.1", port: port, tls: :none, repair_connections: 1],
      article_opts: article_opts]
    {:ok, checker} = Geri.Checker.start_link(c.job, opts)
    try do
      :ok = Geri.Checker.enqueue(checker, item)
      for _ <- 1..if(outcome == :confirmed, do: 1, else: 3), do: advance_check(checker)
      if outcome != :confirmed do
        assert_receive {:repair_waiting, pid}, 2_000
        assert Map.has_key?(:sys.get_state(c.job).verification.files, 1)
        assert Geri.JobState.verification(c.job).missing == 1
        send(pid, :continue)
      end
      result = Geri.Checker.finish(checker)
      assert :sys.get_state(c.job).verification.files == %{}
      assert Geri.JobState.verification(c.job)[outcome] == 1
      if outcome == :repair_failed do
        assert {:error, {:verification_failed, details, []}} = result
        assert [%{outcome: :repair_failed}] = details.unresolved
      else
        assert result == :ok
        assert Geri.JobState.failure_info(c.job).unresolved == []
      end
      send(server.pid, :stop)
      Task.await(server, 2_000)
    after
      GenServer.stop(checker)
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Task.shutdown(server, :brutal_kill)
    end
  end

  defp drain_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> drain_article(socket)
      error -> flunk("article receive failed: #{inspect(error)}")
    end
  end

  defp advance_check(checker) do
    wait_for_check(checker, System.monotonic_time(:millisecond) + 2_000)
    :sys.replace_state(checker, fn state ->
      if state.timer, do: Process.cancel_timer(state.timer)
      now = System.monotonic_time(:millisecond) - 1
      entries = for {{_due, sequence}, item} <- :gb_trees.to_list(state.queue), do: {{now, sequence}, item}
      %{state | queue: :gb_trees.from_orddict(Enum.sort(entries)), timer: nil}
    end)
    send(checker, :dispatch)
  end

  defp wait_for_check(checker, deadline) do
    if :gb_trees.is_empty(:sys.get_state(checker).queue) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      wait_for_check(checker, deadline)
    end
  end
end
