defmodule Geri.NZBPublicationTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-nzb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "upload.nzb")}
  end

  test "successful publication removes part and leaves a complete NZB", c do
    {:ok, writer} = Geri.NZB.open(c.path)
    assert :ok = Geri.NZB.finalize(writer)
    assert File.read!(c.path) =~ "</nzb>\n"
    refute File.exists?(writer.temp_path)
  end

  test "an existing destination is rejected before creating part", c do
    File.write!(c.path, "existing NZB")
    assert {:error, {:nzb_exists, path}} = Geri.NZB.open(c.path)
    assert path == c.path
    assert File.read!(c.path) == "existing NZB"
    refute File.exists?(c.path <> ".part")
  end

  test "footer write errors close the writer and return a finalization error", c do
    {:ok, writer} = Geri.NZB.open(c.path)
    :ok = File.close(writer.io)
    parent = self()
    device = spawn_link(fn -> failing_device(parent) end)

    try do
      assert {:error, {:nzb_finalize_failed, :enospc}} =
               Geri.NZB.finalize(%{writer | io: device})
      assert_receive {:writer_closed, ^device}
      assert File.exists?(writer.temp_path)
      refute File.read!(writer.temp_path) =~ "</nzb>"
      refute File.exists?(writer.path)
    after
      Process.unlink(device)
      if Process.alive?(device), do: Process.exit(device, :kill)
    end
  end

  test "finalizing a closed writer returns an error without publishing", c do
    {:ok, writer} = Geri.NZB.open(c.path)
    :ok = File.close(writer.io)
    assert {:error, {:nzb_finalize_failed, :terminated}} = Geri.NZB.finalize(writer)
    assert File.exists?(writer.temp_path)
    refute File.exists?(writer.path)
  end

  test "an existing part is never truncated", c do
    part = c.path <> ".part"
    File.write!(part, "unfinished NZB")
    assert {:error, {:nzb_temp_exists, ^part}} = Geri.NZB.open(c.path)
    assert File.read!(part) == "unfinished NZB"
  end

  test "a dangling part symlink cannot redirect exclusive creation", c do
    target = Path.join(c.dir, "missing")
    part = c.path <> ".part"
    :ok = File.ln_s(target, part)
    assert {:error, {:nzb_temp_exists, ^part}} = Geri.NZB.open(c.path)
    refute File.exists?(target)
    assert {:ok, ^target} = File.read_link(part)
  end

  test "a dangling destination symlink is an occupied filename", c do
    target = Path.join(c.dir, "missing")
    :ok = File.ln_s(target, c.path)
    assert {:error, {:nzb_exists, _}} = Geri.NZB.open(c.path)
    refute File.exists?(c.path <> ".part")
    refute File.exists?(target)
    assert {:ok, ^target} = File.read_link(c.path)
  end

  test "a destination created during writing is preserved and part remains complete", c do
    {:ok, writer} = Geri.NZB.open(c.path)
    File.write!(c.path, "other upload")
    assert {:error, {:nzb_finalize_failed, :eexist}} = Geri.NZB.finalize(writer)
    assert File.read!(c.path) == "other upload"
    assert File.read!(writer.temp_path) =~ "</nzb>\n"
    assert :ok = Geri.NZB.abort(writer)
    assert File.exists?(writer.temp_path)
  end

  test "a dangling destination created during writing is not replaced", c do
    {:ok, writer} = Geri.NZB.open(c.path)
    target = Path.join(c.dir, "missing")
    :ok = File.ln_s(target, c.path)
    assert {:error, {:nzb_finalize_failed, :eexist}} = Geri.NZB.finalize(writer)
    assert {:ok, ^target} = File.read_link(c.path)
    assert File.read!(writer.temp_path) =~ "</nzb>\n"
  end

  test "a publication filesystem error preserves the completed part", c do
    {:ok, writer} = Geri.NZB.open(c.path)
    writer = %{writer | path: Path.join([c.dir, "missing-directory", "upload.nzb"])}
    assert {:error, {:nzb_finalize_failed, :enoent}} = Geri.NZB.finalize(writer)
    assert File.read!(writer.temp_path) =~ "</nzb>\n"
    refute File.exists?(writer.path)
  end

  test "concurrent opens admit exactly one writer", c do
    parent = self()
    tasks = for _ <- 1..16 do
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (:open -> :ok)
        result = Geri.NZB.open(c.path)
        send(parent, {:opened, self(), result})
        receive do: (:finish -> :ok)
        case result do
          {:ok, writer} -> Geri.NZB.abort(writer)
          _ -> :ok
        end
        result
      end)
    end

    try do
      for _ <- tasks, do: assert_receive({:ready, _}, 2_000)
      Enum.each(tasks, &send(&1.pid, :open))
      results = for _ <- tasks do
        assert_receive {:opened, _pid, result}, 2_000
        result
      end
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:nzb_temp_exists, _}}, &1)) == 15
      Enum.each(tasks, &send(&1.pid, :finish))
      Enum.each(tasks, &Task.await(&1, 2_000))
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  test "concurrent publishers cannot replace the winner", c do
    writers = for name <- ["first", "second"] do
      {:ok, writer} = Geri.NZB.open(Path.join(c.dir, name <> ".nzb"))
      :ok = IO.binwrite(writer.io, "<!-- #{name} -->\n")
      %{writer | path: c.path}
    end
    tasks = Enum.map(writers, fn writer -> Task.async(fn -> Geri.NZB.finalize(writer) end) end)
    results = Task.await_many(tasks, 2_000)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, {:nzb_finalize_failed, :eexist}})) == 1
    for {writer, result} <- Enum.zip(writers, results) do
      if result == :ok do
        refute File.exists?(writer.temp_path)
      else
        assert File.read!(writer.temp_path) =~ "</nzb>\n"
      end
    end
    assert File.read!(c.path) =~ "</nzb>\n"
  end

  test "upload returns a finalization error without overwriting another NZB", c do
    source = Path.join(c.dir, "source.bin")
    File.write!(source, "hello")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    server = Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2_000)
      :ok = :gen_tcp.send(socket, "200 ready\r\n")
      assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
      :ok = :gen_tcp.send(socket, "340 send article\r\n")
      receive_article(socket)
      File.write!(c.path, "other upload")
      :ok = :gen_tcp.send(socket, "240 received\r\n")
      assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)
    end)
    try do
      assert {:error, {:finalization_failed, {:nzb_finalize_failed, :eexist}, details}} =
               Geri.upload(source, host: "127.0.0.1", port: port, tls: :none,
                 auth_file: false, from: "test@example.invalid", newsgroups: ["test"],
                 connections: 1, nzb: c.path)
      assert is_binary(details.upload_key)
      assert File.read!(c.path) == "other upload"
      assert File.read!(c.path <> ".part") =~ "</nzb>\n"
      assert :ok = Task.await(server, 2_000)
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> receive_article(socket)
    end
  end

  defp failing_device(parent) do
    receive do
      {:io_request, caller, ref, {:put_chars, :latin1, _data}} ->
        send(caller, {:io_reply, ref, {:error, :enospc}})
        failing_device(parent)

      {:file_request, caller, ref, :close} ->
        send(parent, {:writer_closed, self()})
        send(caller, {:file_reply, ref, :ok})
    end
  end
end
