defmodule Geri.OptionsTest.Observer do
  @behaviour :gen_event
  def init(parent), do: {:ok, parent}
  def handle_call({:attach, nil}, parent), do: {:ok, :ok, parent}

  def handle_call({:attach, control}, parent) do
    context = Geri.Control.context(control)
    send(parent, {:normalized_upload, control, Geri.JobState.snapshot(context.job), context.opts})
    {:ok, :ok, parent}
  end

  def handle_event(_event, parent), do: {:ok, parent}
  def handle_info(_message, parent), do: {:ok, parent}
  def terminate(_reason, _parent), do: :ok
  def code_change(_old, parent, _extra), do: {:ok, parent}
end

defmodule Geri.OptionsTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-options-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, "hello")
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      host: "127.0.0.1",
      from: "test@example.invalid",
      newsgroups: ["test"],
      auth_file: false
    ]

    %{dir: dir, path: path, opts: opts, nzb: Path.join(dir, "upload.nzb")}
  end

  test "normalization supplies execution defaults and preserves independent role settings", c do
    assert {:ok, [path], opts} = Geri.Options.normalize(c.path, c.opts)
    assert path == c.path
    assert opts[:connections] == 8
    assert opts[:part_size] == 700 * 1024
    assert opts[:encoding] == :yenc
    assert opts[:tls] == :implicit
    assert opts[:port] == 563
    assert opts[:check_connections] == 2
    assert opts[:repair_connections] == 2

    for tls <- [:none, :starttls] do
      assert {:ok, _, normalized} = Geri.Options.normalize(c.path, Keyword.put(c.opts, :tls, tls))
      assert normalized[:port] == 119
    end

    role_opts =
      Keyword.merge(c.opts, check_host: "b.invalid", check_tls: :none, repair_connections: 3)

    assert {:ok, _, normalized} = Geri.Options.normalize(c.path, role_opts)
    refute Keyword.has_key?(normalized, :repair_host)
    refute Keyword.has_key?(normalized, :repair_tls)
    assert normalized[:repair_connections] == 3
  end

  test "effective encoding part sizes follow the encoders' actual sizes", c do
    for {encoding, size, expected} <- [{:base64, 58, 57}, {:uuencode, 46, 45}, {:yenc, 58, 58}] do
      opts = Keyword.merge(c.opts, encoding: encoding, part_size: size)
      assert {:ok, _, normalized} = Geri.Options.normalize(c.path, opts)
      assert normalized[:part_size] == expected
    end
  end

  test "invalid options return errors before NZB creation or authentication lookup", c do
    for {key, value} <- [
          port: 65536,
          check_port: 0,
          repair_port: -1,
          connections: 0,
          check_connections: "2",
          repair_connections: nil,
          reconnect_delay: -1,
          encoding: :unknown,
          tls: :unknown,
          check_tls_verify: :unknown,
          from: " ",
          host: "",
          check_host: "\t",
          repair_host: " ",
          newsgroups: [""],
          newsgroups: "test,",
          part_size: 0
        ] do
      opts = Keyword.merge(c.opts, [{key, value}, {:nzb, c.nzb}, {:auth_file, c.dir}])
      assert {:error, {:invalid_option, ^key, _}} = Geri.upload(c.path, opts)
      refute File.exists?(c.nzb <> ".part")
    end
  end

  test "all role ports accept boundaries and reject nonintegers or out-of-range values", c do
    for key <- [:port, :check_port, :repair_port] do
      for value <- [1, 65535] do
        assert {:ok, _, _} = Geri.Options.normalize(c.path, Keyword.put(c.opts, key, value))
      end

      for value <- [0, -1, 65536, "119", nil] do
        assert {:error, {:invalid_option, ^key, :port_out_of_range}} =
                 Geri.upload(c.path, Keyword.put(c.opts, key, value))
      end
    end
  end

  test "encoding-specific minimum sizes fail before creating output", c do
    for {encoding, minimum} <- [base64: 57, uuencode: 45, yenc: 1] do
      opts = Keyword.merge(c.opts, encoding: encoding, part_size: minimum - 1, nzb: c.nzb)

      assert {:error, {:invalid_option, :part_size, {:minimum_bytes, ^minimum}}} =
               Geri.upload(c.path, opts)

      refute File.exists?(c.nzb <> ".part")
    end
  end

  test "invalid file sets and nonregular inputs fail before creating output", c do
    opts = Keyword.put(c.opts, :nzb, c.nzb)
    assert {:error, :files_required} = Geri.upload([], opts)
    assert {:error, {:invalid_input, _, :not_regular_file}} = Geri.upload(c.dir, opts)
    assert {:error, {:invalid_input, 42, :path_required}} = Geri.upload([42], opts)
    missing = Path.join(c.dir, "missing")
    assert {:error, {:file_stat_failed, ^missing, :enoent}} = Geri.upload(missing, opts)
    File.write!(c.path, "")
    assert {:error, {:invalid_input, _, :empty_file}} = Geri.upload(c.path, opts)
    refute File.exists?(c.nzb <> ".part")
  end

  test "missing required values and repair without checking fail normally", c do
    for key <- [:host, :from, :newsgroups] do
      assert {:error, {:invalid_option, ^key, _}} =
               Geri.upload(c.path, Keyword.delete(c.opts, key))
    end

    assert {:error, {:invalid_option, :repair_host, :checking_server_required}} =
             Geri.upload(c.path, Keyword.put(c.opts, :repair_host, "c.invalid"))

    assert {:error, :invalid_options} = Geri.upload(c.path, %{})
  end

  test "CLI shares semantic validation and keeps string parsing and help behavior", c do
    base = ["upload", "--host", "localhost", "--from", "test@example.invalid", "--group", "test"]

    assert {:error, "--port must be an integer between 1 and 65535"} =
             Geri.CLI.run(base ++ ["--port", "65536", "--", c.path])

    assert {:error, "--part-size must be at least 57 bytes for this encoding"} =
             Geri.CLI.run(base ++ ["--encoding", "base64", "--part-size", "1", "--", c.path])

    assert {:error, "invalid --part-size: " <> _} =
             Geri.CLI.run(base ++ ["--part-size", "bad", "--", c.path])

    assert {:error, "at least one file is required"} = Geri.CLI.run(base)

    assert {:error, message} = Geri.CLI.run(base ++ ["--", c.dir])
    assert message =~ "a regular file is required"

    assert ExUnit.CaptureIO.capture_io(fn -> assert :ok = Geri.CLI.run(["upload", "--help"]) end) =~
             "Usage:"
  end

  test "real upload workers and snapshots receive the same normalized defaults", c do
    handler = {Geri.OptionsTest.Observer, make_ref()}
    :ok = :gen_event.add_handler(:erl_signal_server, handler, self())

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        send(parent, {:posting_socket, self()})

        receive do
          :continue -> :ok
        after
          2_000 -> flunk("server was not released")
        end

        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, "340 send article\r\n")
        read_article(socket)
        :ok = :gen_tcp.send(socket, "240 accepted\r\n")
        assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
      end)

    upload =
      Task.async(fn ->
        Geri.upload(
          c.path,
          Keyword.merge(c.opts, port: port, tls: :none, signal_handler: handler)
        )
      end)

    try do
      assert_receive {:normalized_upload, control, snapshot, opts}, 2_000
      assert snapshot.connections == 8
      assert opts[:connections] == snapshot.connections
      assert opts[:part_size] == 700 * 1024
      assert_receive {:posting_socket, server_pid}, 2_000
      assert length(wait_for_workers(control, System.monotonic_time(:millisecond) + 2_000)) == 8
      assert :sys.get_state(Geri.Control.context(control).job).job.part_size == opts[:part_size]
      send(server_pid, :continue)
      assert {:ok, _key} = Task.await(upload, 2_000)
      assert :ok = Task.await(server, 2_000)
    after
      :gen_tcp.close(listener)
      Task.shutdown(upload, :brutal_kill)
      Task.shutdown(server, :brutal_kill)
      :gen_event.delete_handler(:erl_signal_server, handler, [])
    end
  end

  test "JobState snapshots use the same default connection and part sizes", c do
    {:ok, job} = Geri.JobState.start_link("key", [c.path], c.opts)

    try do
      assert Geri.JobState.snapshot(job).connections == Geri.defaults()[:connections]
      assert :sys.get_state(job).job.part_size == Geri.defaults()[:part_size]
    after
      GenServer.stop(job)
    end
  end

  defp read_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _} -> read_article(socket)
    end
  end

  defp wait_for_workers(control, deadline) do
    case Geri.Control.context(control)[:workers] do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        wait_for_workers(control, deadline)

      workers ->
        workers
    end
  end
end
