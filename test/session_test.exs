defmodule Geri.SessionTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    {:ok, control} = Geri.Control.start_link()
    Process.unlink(control)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(control), do: GenServer.stop(control)
    end)

    opts = [
      host: "127.0.0.1",
      port: port,
      tls: :none,
      control: control,
      username: "alice",
      password: "secret"
    ]

    %{listener: listener, control: control, opts: opts}
  end

  test "reader mode precedes registered authentication and success leaves checkin to the caller",
       c do
    client = self()

    server =
      serve(c, fn socket ->
        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "MODE READER\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, "200 reader ready\r\n")
        assert {:ok, "AUTHINFO USER alice\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        actor = :sys.get_state(c.control).actors[client]
        assert actor.busy
        assert %Geri.NNTP{} = actor.conn
        :ok = :gen_tcp.send(socket, "381 password required\r\n")
        assert {:ok, "AUTHINFO PASS secret\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, "281 authenticated\r\n")
        assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    assert {:ok, nil} = Geri.Control.checkout(c.control, nil)
    assert {:ok, conn} = Geri.Session.connect(Keyword.put(c.opts, :reader, true))
    assert :sys.get_state(c.control).actors[self()].busy
    assert conn == Geri.Control.checkin(c.control, conn)
    Geri.NNTP.quit(conn)
    Geri.Control.release(c.control)
    assert :ok = Task.await(server, 2_000)
  end

  test "authentication rejection preserves the reason and closes the socket", c do
    server =
      serve(c, fn socket ->
        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "AUTHINFO USER alice\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, "481 denied\r\n")
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    Geri.Control.checkout(c.control, nil)
    assert {:error, {:authentication_failed, 481, "denied"}} = Geri.Session.connect(c.opts)
    Geri.Control.checkin(c.control, nil)
    Geri.Control.release(c.control)
    assert :ok = Task.await(server, 2_000)
  end

  test "greeting rejection closes before registration or authentication", c do
    server =
      serve(c, fn socket ->
        :ok = :gen_tcp.send(socket, "500 unavailable\r\n")
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    Geri.Control.checkout(c.control, nil)
    assert {:error, {:unexpected_greeting, 500, "unavailable"}} = Geri.Session.connect(c.opts)
    assert :sys.get_state(c.control).actors[self()].conn == nil
    Geri.Control.checkin(c.control, nil)
    Geri.Control.release(c.control)
    assert :ok = Task.await(server, 2_000)
  end

  test "cancellation during setup closes a newly acquired socket without AUTHINFO", c do
    parent = self()

    server =
      serve(c, fn socket ->
        send(parent, {:greeting_waiting, self()})

        receive do
          :greet -> :ok
        after
          2_000 -> flunk("greeting was not released")
        end

        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    client = connect_task(c)

    assert_receive {:greeting_waiting, server_pid}, 2_000
    assert :ok = Geri.Control.cancel(c.control)
    send(server_pid, :greet)
    assert {{:error, :cancelled}, nil} = Task.await(client, 2_000)
    assert :ok = Task.await(server, 2_000)
  end

  test "cancellation can interrupt a registered socket stalled in authentication", c do
    parent = self()

    server =
      serve(c, fn socket ->
        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "AUTHINFO USER alice\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, :authentication_waiting)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    client = connect_task(c)

    assert_receive :authentication_waiting, 2_000
    assert %Geri.NNTP{} = :sys.get_state(c.control).actors[client.pid].conn
    assert :ok = Geri.Control.cancel(c.control)
    # Exercise the grace-period closure without waiting ten seconds.
    send(c.control, :cancel_timeout)
    assert {{:error, {:recv_failed, :closed}}, nil} = Task.await(client, 2_000)
    assert :ok = Task.await(server, 2_000)
  end

  test "pause during authentication lets setup finish and caller checkin closes it", c do
    parent = self()

    server =
      serve(c, fn socket ->
        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "AUTHINFO USER alice\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, {:authentication_waiting, self()})

        receive do
          :authenticate -> :ok
        after
          2_000 -> flunk("authentication was not released")
        end

        :ok = :gen_tcp.send(socket, "281 authenticated\r\n")
        assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    client = connect_task(c)

    assert_receive {:authentication_waiting, server_pid}, 2_000
    assert :ok = Geri.Control.pause(c.control)
    assert :pausing = Geri.Control.mode(c.control)
    send(server_pid, :authenticate)
    assert {{:ok, %Geri.NNTP{}}, nil} = Task.await(client, 2_000)
    assert :paused = Geri.Control.mode(c.control)
    assert :ok = Task.await(server, 2_000)
  end

  test "setup also works without Control or authentication", c do
    server =
      serve(c, fn socket ->
        :ok = :gen_tcp.send(socket, "200 ready\r\n")
        assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
        :ok
      end)

    opts = Keyword.drop(c.opts, [:control, :username, :password])
    assert {:ok, conn} = Geri.Session.connect(opts)
    Geri.NNTP.quit(conn)
    assert :ok = Task.await(server, 2_000)
  end

  defp connect_task(c) do
    task =
      Task.async(fn ->
        {:ok, nil} = Geri.Control.checkout(c.control, nil)
        result = Geri.Session.connect(c.opts)

        conn =
          case result do
            {:ok, conn} -> conn
            {:error, _} -> nil
          end

        checked_in = Geri.Control.checkin(c.control, conn)
        Geri.Control.release(c.control)
        {result, checked_in}
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp serve(c, fun) do
    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(c.listener, 2_000)

        try do
          fun.(socket)
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end
end
