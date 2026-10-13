defmodule Geri.UploadShutdownTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-shutdown-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "source.bin")
    File.write!(path, :binary.copy("a", 114))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path, nzb: Path.join(dir, "upload.nzb")}
  end

  test "posting failure stops a peer sleeping between reconnect attempts", c do
    run_upload(c, fn listener ->
      retrying = accept_post(listener)
      rejecting = accept_post(listener)
      :gen_tcp.close(retrying)

      # The retry fails, putting its worker into the three-minute retry delay.
      {:ok, retry} = :gen_tcp.accept(listener, 2_000)
      :ok = :gen_tcp.send(retry, "500 unavailable\r\n")
      assert {:error, :closed} = :gen_tcp.recv(retry, 0, 2_000)
      :gen_tcp.close(retry)
      reject_post(rejecting)
    end, 2_000)
  end

  @tag timeout: 20_000
  test "posting failure interrupts a peer waiting for a POST response", c do
    run_upload(c, fn listener ->
      stalled = accept_post(listener)
      rejecting = accept_post(listener)
      reject_post(rejecting)
      # The existing cancellation grace period closes an active operation.
      assert {:error, :closed} = :gen_tcp.recv(stalled, 0, 15_000)
      :gen_tcp.close(stalled)
    end, 15_000)
  end

  test "producer failure stops a peer reconnecting while another worker posts", c do
    second = Path.join(Path.dirname(c.path), "second.bin")
    File.write!(second, "second file")
    File.write!(c.path, :binary.copy("a", 570))
    run_upload(%{c | path: [c.path, second]}, fn listener ->
      retrying = accept_post(listener)
      posting = accept_post(listener)
      :gen_tcp.close(retrying)
      {:ok, retry} = :gen_tcp.accept(listener, 2_000)
      :ok = :gen_tcp.send(retry, "500 unavailable\r\n")
      assert {:error, :closed} = :gen_tcp.recv(retry, 0, 2_000)
      :gen_tcp.close(retry)

      # Initialization saw both files; remove the second before encoding it.
      File.rm!(second)
      complete_posts(posting)
    end, 2_000, :enoent)
  end

  defp run_upload(c, serve, timeout, reason \\ {:post_rejected, 440, "posting denied"}) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    server = Task.async(fn -> serve.(listener) end)
    upload = Task.async(fn ->
      Geri.upload(c.path,
        host: "127.0.0.1", port: port, tls: :none, auth_file: false,
        from: "test@example.invalid", newsgroups: ["test"], connections: 2,
        part_size: 57, encoding: :base64, reconnect_delay: 180_000, nzb: c.nzb
      )
    end)

    try do
      assert {:error, {:upload_failed, ^reason, details}} =
               Task.await(upload, timeout)
      assert is_binary(details.upload_key)
      assert File.exists?(c.nzb <> ".part")
      refute File.exists?(c.nzb)
      assert :ok = Task.await(server, 1_000)
    after
      :gen_tcp.close(listener)
      Task.shutdown(upload, :brutal_kill)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp accept_post(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    :ok = :gen_tcp.send(socket, "200 ready\r\n")
    assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    socket
  end

  defp reject_post(socket) do
    :ok = :gen_tcp.send(socket, "440 posting denied\r\n")
    assert {:ok, "STAT " <> _} = :gen_tcp.recv(socket, 0, 2_000)
    :ok = :gen_tcp.send(socket, "430 missing\r\n")
    assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
  end

  defp complete_posts(socket) do
    :ok = :gen_tcp.send(socket, "340 send article\r\n")
    receive_article(socket)
    :gen_tcp.send(socket, "240 received\r\n")
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, "POST\r\n"} -> complete_posts(socket)
      {:ok, "QUIT\r\n"} -> :gen_tcp.close(socket)
      {:error, :closed} -> :gen_tcp.close(socket)
    end
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> receive_article(socket)
    end
  end
end
