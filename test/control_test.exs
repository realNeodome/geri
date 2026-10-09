defmodule Geri.ControlTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, control} = Geri.Control.start_link()
    %{control: control}
  end

  test "pause blocks new work until resume", %{control: control} do
    assert :ok = Geri.Control.pause(control)
    task = Task.async(fn -> Geri.Control.await(control) end)
    assert Task.yield(task, 20) == nil
    assert :ok = Geri.Control.resume(control)
    assert :ok = Task.await(task)
  end

  test "cancel releases paused work and cannot be resumed", %{control: control} do
    Geri.Control.pause(control)
    task = Task.async(fn -> Geri.Control.await(control) end)
    assert :ok = Geri.Control.cancel(control)
    assert {:error, :cancelled} = Task.await(task)
    assert {:error, :cancelled} = Geri.Control.resume(control)
    assert :already_cancelled = Geri.Control.cancel(control)
  end

  test "cancel wakes a worker waiting on an empty queue", %{control: control} do
    {:ok, queue} = Geri.Queue.start_link(1)
    Geri.Control.register_queue(control, queue)
    task = Task.async(fn -> Geri.Queue.next(queue) end)
    Geri.Control.cancel(control)
    assert {:error, :cancelled} = Task.await(task)
  end

  test "pause closes idle connections with QUIT and resumes without a stale socket", %{control: control} do
    {conn, peer, listener} = connection()
    assert {:ok, ^conn} = Geri.Control.checkout(control, conn)
    assert ^conn = Geri.Control.checkin(control, conn)
    Geri.Control.pause(control)
    assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(peer, 0, 1_000)
    assert {:error, :closed} = :gen_tcp.recv(peer, 0, 1_000)
    Geri.Control.resume(control)
    assert {:ok, nil} = Geri.Control.checkout(control, conn)
    Geri.Control.checkin(control, nil)
    :gen_tcp.close(peer)
    :gen_tcp.close(listener)
  end

  test "pause lets an active operation finish before closing its connection", %{control: control} do
    {conn, peer, listener} = connection()
    Geri.Control.checkout(control, conn)
    Geri.Control.pause(control)
    assert {:error, :timeout} = :gen_tcp.recv(peer, 0, 20)
    assert nil == Geri.Control.checkin(control, conn)
    assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(peer, 0, 1_000)
    assert :ok = Geri.Control.await_idle(control)
    :gen_tcp.close(peer)
    :gen_tcp.close(listener)
  end

  test "cancel timeout closes a busy socket to interrupt a stalled operation", %{control: control} do
    {conn, peer, listener} = connection()
    Geri.Control.checkout(control, conn)
    Geri.Control.cancel(control)
    send(control, :cancel_timeout)
    assert {:error, :closed} = :gen_tcp.recv(peer, 0, 1_000)
    Geri.Control.checkin(control, nil)
    :gen_tcp.close(peer)
    :gen_tcp.close(listener)
  end

  defp connection do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line])
    {:ok, peer} = :gen_tcp.accept(listener)
    {%Geri.NNTP{socket: socket, transport: :tcp, host: "localhost"}, peer, listener}
  end
end
