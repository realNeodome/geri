defmodule Geri.PauseActivityTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "geri-pause-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "sample.bin")
    File.write!(path, "data")

    {:ok, job} =
      Geri.JobState.start_link("pause-key", [path],
        from: "test@example.com",
        newsgroups: ["test"]
      )

    {:ok, control} = Geri.Control.start_link()
    Geri.Control.put_context(control, %{job: job})
    on_exit(fn -> File.rm_rf!(root) end)
    %{control: control, job: job}
  end

  test "an idle job records both pause phases once and resumes once", c do
    assert :ok = Geri.Control.pause(c.control)
    assert Geri.Control.mode(c.control) == :paused
    assert messages(c) == ["preparing to pause Geri", "Geri paused"]
    Geri.Control.pause(c.control)
    assert length(events(c)) == 2
    Geri.Control.resume(c.control)
    Geri.Control.resume(c.control)
    assert messages(c) == ["preparing to pause Geri", "Geri paused", "Geri resumed"]
  end

  test "busy workers keep PAUSING until their connection closes and block new work", c do
    {conn, peer, listener} = connection()

    try do
      assert {:ok, ^conn} = Geri.Control.checkout(c.control, conn, 1)
      Geri.Control.pause(c.control)
      assert Geri.Control.mode(c.control) == :pausing
      assert messages(c) == ["preparing to pause Geri"]
      assert {:error, :timeout} = :gen_tcp.recv(peer, 0, 20)
      waiting = Task.async(fn -> Geri.Control.await(c.control) end)
      assert Task.yield(waiting, 20) == nil
      assert nil == Geri.Control.checkin(c.control, conn)
      assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(peer, 0, 1_000)
      assert Geri.Control.mode(c.control) == :paused
      assert :ok = Geri.Control.await_idle(c.control)
      assert messages(c) == ["preparing to pause Geri", "connection closed", "Geri paused"]
      assert Enum.at(events(c), 1).worker == 1
      Geri.Control.resume(c.control)
      assert :ok = Task.await(waiting)
    after
      :gen_tcp.close(peer)
      :gen_tcp.close(listener)
    end
  end

  test "idle checker and repair connections close before a busy actor permits PAUSED", c do
    {conn, peer, listener} = connection()
    {other, peer2, listener2} = connection()
    Geri.Control.checkout(c.control, conn, "C1")
    Geri.Control.checkin(c.control, conn)
    repair = actor(c.control, other, "R2")

    try do
      Geri.Control.pause(c.control)
      assert Geri.Control.mode(c.control) == :pausing
      assert Enum.map(events(c), & &1.worker) == [nil, "C1"]
      assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(peer, 0, 1_000)
      send(repair.pid, :checkin)
      assert_receive {:checked_in, pid}
      assert pid == repair.pid
      assert Geri.Control.mode(c.control) == :paused
      assert Enum.map(events(c), & &1.worker) == [nil, "C1", "R2", nil]
      assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(peer2, 0, 1_000)
    after
      Task.shutdown(repair, :brutal_kill)
      for socket <- [peer, listener, peer2, listener2], do: :gen_tcp.close(socket)
    end
  end

  test "resuming during PAUSING cannot produce a stale paused event", c do
    Geri.Control.checkout(c.control, nil, 1)
    Geri.Control.pause(c.control)
    assert Geri.Control.mode(c.control) == :pausing
    Geri.Control.resume(c.control)
    assert nil == Geri.Control.checkin(c.control, nil)
    assert Geri.Control.mode(c.control) == :running
    assert messages(c) == ["preparing to pause Geri", "Geri resumed"]
  end

  test "cancellation during PAUSING never reports PAUSED or resumed", c do
    Geri.Control.checkout(c.control, nil, 1)
    Geri.Control.pause(c.control)
    Geri.Control.cancel(c.control)
    Geri.Control.checkin(c.control, nil)
    assert Geri.Control.mode(c.control) == :cancelled
    assert {:error, :cancelled} = Geri.Control.resume(c.control)
    assert messages(c) == ["preparing to pause Geri"]
  end

  test "the last active worker exiting completes the pause without a fake closure", c do
    worker = actor(c.control, nil, 1)
    Geri.Control.pause(c.control)
    assert Geri.Control.mode(c.control) == :pausing
    Task.shutdown(worker, :brutal_kill)
    wait_until(fn -> Geri.Control.mode(c.control) == :paused end)
    assert messages(c) == ["preparing to pause Geri", "Geri paused"]
  end

  test "new control activity shares the existing bounded activity history", c do
    for n <- 1..100, do: Geri.JobState.activity(c.job, "event #{n}")
    assert length(events(c)) == 64
    assert List.last(messages(c)) == "event 100"
    assert Enum.all?(events(c), &(&1.kind == :control))
  end

  defp events(c) do
    # A barrier in the sender ensures all earlier control casts were delivered.
    :sys.get_state(c.control)
    Geri.JobState.snapshot(c.job).activity |> Enum.reverse()
  end

  defp messages(c), do: Enum.map(events(c), & &1.message)

  defp actor(control, conn, label) do
    parent = self()

    task =
      Task.async(fn ->
        Geri.Control.checkout(control, conn, label)
        send(parent, {:ready, self()})

        receive do
          :checkin ->
            Geri.Control.checkin(control, conn)
            send(parent, {:checked_in, self()})

            receive do
              :stop -> Geri.Control.release(control)
            end
        end
      end)

    assert_receive {:ready, pid}
    assert pid == task.pid
    task
  end

  defp wait_until(fun, remaining \\ 100) do
    cond do
      fun.() ->
        :ok

      remaining > 0 ->
        Process.sleep(5)
        wait_until(fun, remaining - 1)

      true ->
        flunk("pause did not settle")
    end
  end

  defp connection do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line])

    {:ok, peer} = :gen_tcp.accept(listener)
    {%Geri.NNTP{socket: socket, transport: :tcp, host: "localhost"}, peer, listener}
  end
end
