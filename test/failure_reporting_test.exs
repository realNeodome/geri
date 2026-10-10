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
end
