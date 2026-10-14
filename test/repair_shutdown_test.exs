defmodule Geri.RepairShutdownTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-repair-stop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    first = Path.join(dir, "first.bin")
    second = Path.join(dir, "second.bin")
    File.write!(first, :binary.copy("a", 570))
    File.write!(second, "second file")
    {:ok, control} = Geri.Control.start_link()
    Process.unlink(control)

    opts = [
      from: "test@example.invalid",
      newsgroups: ["test"],
      upload_key: "repair-key",
      control: control
    ]

    {:ok, job} = Geri.JobState.start_link("repair-key", [first, second], opts)
    Process.unlink(job)

    items =
      for {path, number} <- Enum.with_index([first, second], 1), reduce: [] do
        acc ->
          {:ok, stream} = Geri.Encoder.Base64.stream_file(path, 57)

          acc ++
            Enum.map(stream, fn part ->
              part =
                Map.merge(part, %{
                  file_number: number,
                  file_total: 2,
                  offset: (part.part - 1) * 57
                })

              {:ok, article} = Geri.Article.build(part, opts)

              part
              |> Map.delete(:body)
              |> Map.put(:path, path)
              |> Map.put(:part_total, part.total)
              |> Map.put(:message_id, article.message_id)
            end)
      end

    on_exit(fn ->
      if Process.alive?(job), do: GenServer.stop(job)
      if Process.alive?(control), do: GenServer.stop(control)
      File.rm_rf!(dir)
    end)

    %{second: second, control: control, job: job, opts: opts, items: items}
  end

  test "fatal repair producer error wakes a reconnecting peer and leaves posting work alone", c do
    # Model another live posting pool registered with the same coordinator.
    {:ok, posting_queue} = Geri.Queue.start_link(1)
    Geri.Control.register_queue(c.control, posting_queue)
    Geri.Queue.push(posting_queue, :unrelated_post)
    parent = self()

    posting_worker =
      Task.async(fn ->
        {:ok, nil} = Geri.Control.checkout(c.control, nil)
        nil = Geri.Control.checkin(c.control, nil)
        send(parent, :posting_ready)

        receive do
          :stop -> Geri.Control.release(c.control)
          {:cancelled, _} -> flunk("repair failure cancelled the posting pool")
        end
      end)

    assert_receive :posting_ready

    try do
      run_repair(c, fn listener ->
        retrying = accept_post(listener)
        posting = accept_post(listener)
        :gen_tcp.close(retrying)
        {:ok, retry} = :gen_tcp.accept(listener, 2_000)
        :ok = :gen_tcp.send(retry, "500 unavailable\r\n")
        assert {:error, :closed} = :gen_tcp.recv(retry, 0, 2_000)
        :gen_tcp.close(retry)
        File.rm!(c.second)
        complete_posts(posting)
      end)

      assert Geri.Control.mode(c.control) == :running
      assert Process.alive?(posting_worker.pid)
      assert {:ok, :unrelated_post} = Geri.Queue.next(posting_queue)
      send(posting_worker.pid, :stop)
      assert :ok = Task.await(posting_worker, 1_000)
    after
      Task.shutdown(posting_worker, :brutal_kill)
      GenServer.stop(posting_queue)
    end
  end

  test "fatal repair producer error interrupts a peer waiting for a POST response", c do
    run_repair(c, fn listener ->
      stalled = accept_post(listener)
      posting = accept_post(listener)
      File.rm!(c.second)
      complete_posts(posting)
      assert {:error, reason} = :gen_tcp.recv(stalled, 0, 2_000)
      assert reason in [:closed, :enotconn, :econnreset]
      :gen_tcp.close(stalled)
    end)

    assert Geri.Control.mode(c.control) == :running
  end

  defp run_repair(c, serve) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    server = Task.async(fn -> serve.(listener) end)

    repair =
      Task.async(fn ->
        Geri.repair(
          c.items,
          c.job,
          [
            host: "127.0.0.1",
            port: port,
            tls: :none,
            repair_connections: 2,
            reconnect_delay: 180_000,
            control: c.control
          ],
          c.opts
        )
      end)

    try do
      expected = {:repair_open_failed, c.second, :enoent}
      assert {:error, ^expected} = Task.await(repair, 2_000)
      assert :ok = Task.await(server, 1_000)
      assert Geri.JobState.failure_info(c.job).upload_key == "repair-key"
    after
      :gen_tcp.close(listener)
      Task.shutdown(repair, :brutal_kill)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp accept_post(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    :ok = :gen_tcp.send(socket, "200 ready\r\n")
    assert {:ok, "POST\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    socket
  end

  defp complete_posts(socket) do
    # Batch failure can close the socket during either response write.
    case :gen_tcp.send(socket, "340 send article\r\n") do
      :ok ->
        receive_article(socket)
        :gen_tcp.send(socket, "240 received\r\n")

        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, "POST\r\n"} ->
            complete_posts(socket)

          {:ok, "QUIT\r\n"} ->
            :gen_tcp.close(socket)

          {:error, reason} when reason in [:closed, :enotconn, :econnreset] ->
            :gen_tcp.close(socket)
        end

      {:error, reason} when reason in [:closed, :enotconn, :econnreset] ->
        :gen_tcp.close(socket)
    end
  end

  defp receive_article(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> receive_article(socket)
      {:error, reason} when reason in [:closed, :enotconn, :econnreset] -> :ok
    end
  end
end
