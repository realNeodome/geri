defmodule Geri.Queue do
  use GenServer

  def start_link(capacity) when capacity > 0 do
    GenServer.start_link(__MODULE__, capacity)
  end

  def push(queue, item) do
    GenServer.call(queue, {:push, item}, :infinity)
  end

  def next(queue) do
    GenServer.call(queue, :next, :infinity)
  end

  def close(queue) do
    GenServer.call(queue, :close)
  end

  def abort(queue, reason) do
    GenServer.call(queue, {:abort, reason})
  end

  @impl true
  def init(capacity) do
    {:ok,
     %{
       capacity: capacity,
       ready: :queue.new(),
       consumers: :queue.new(),
       producers: :queue.new(),
       closed: false,
       error: nil
     }}
  end

  @impl true
  def handle_call({:push, _item}, _from, %{error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:push, _item}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:push, item}, from, state) do
    case :queue.out(state.consumers) do
      {{:value, consumer}, consumers} ->
        GenServer.reply(consumer, {:ok, item})

        {:reply, :ok,
         %{
           state
           | consumers: consumers
         }}

      {:empty, _} ->
        if :queue.len(state.ready) < state.capacity do
          ready = :queue.in(item, state.ready)

          {:reply, :ok,
           %{
             state
             | ready: ready
           }}
        else
          producers = :queue.in({from, item}, state.producers)

          {:noreply,
           %{
             state
             | producers: producers
           }}
        end
    end
  end

  def handle_call(:next, _from, %{error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(:next, from, state) do
    case :queue.out(state.ready) do
      {{:value, item}, ready} ->
        {ready, producers} =
          admit_producer(
            ready,
            state.producers
          )

        {:reply, {:ok, item},
         %{
           state
           | ready: ready,
             producers: producers
         }}

      {:empty, _} when state.closed ->
        {:reply, :done, state}

      {:empty, _} ->
        consumers =
          :queue.in(
            from,
            state.consumers
          )

        {:noreply,
         %{
           state
           | consumers: consumers
         }}
    end
  end

  def handle_call(:close, _from, state) do
    consumers =
      if :queue.is_empty(state.ready) do
        reply_all(
          state.consumers,
          :done
        )

        :queue.new()
      else
        state.consumers
      end

    {:reply, :ok,
     %{
       state
       | closed: true,
         consumers: consumers
     }}
  end

  def handle_call({:abort, reason}, _from, state) do
    reply_all(
      state.consumers,
      {:error, reason}
    )

    reply_producers(
      state.producers,
      {:error, reason}
    )

    {:reply, :ok,
     %{
       state
       | ready: :queue.new(),
         consumers: :queue.new(),
         producers: :queue.new(),
         error: reason
     }}
  end

  defp admit_producer(ready, producers) do
    case :queue.out(producers) do
      {{:value, {from, item}}, producers} ->
        GenServer.reply(from, :ok)

        {
          :queue.in(item, ready),
          producers
        }

      {:empty, _} ->
        {
          ready,
          producers
        }
    end
  end

  defp reply_all(queue, reply) do
    queue
    |> :queue.to_list()
    |> Enum.each(fn from ->
      GenServer.reply(from, reply)
    end)
  end

  defp reply_producers(queue, reply) do
    queue
    |> :queue.to_list()
    |> Enum.each(fn {from, _item} ->
      GenServer.reply(from, reply)
    end)
  end
end
