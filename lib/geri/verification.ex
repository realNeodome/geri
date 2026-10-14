defmodule Geri.Verification do
  @moduledoc false

  @outcomes [:confirmed, :missing, :repaired, :repair_failed, :inconclusive]

  def new do
    %{totals: empty_totals(), files: %{}, unresolved: %{}, frontier: 0, finished: MapSet.new()}
  end

  def accepts?(state, kind, item) do
    file = Map.get_lazy(state.files, item.file_number, &empty_file/0)

    not finished?(state, item.file_number) and
      if kind == :pending do
        not Map.has_key?(state.unresolved, {item.file_number, item.part}) and
          not Enum.any?(@outcomes, &MapSet.member?(file[&1], item.part))
      else
        not MapSet.member?(file[kind], item.part)
      end
  end

  def record(state, kind, item) do
    if accepts?(state, kind, item) do
      file = Map.get_lazy(state.files, item.file_number, &empty_file/0)

      file =
        if kind == :pending, do: file, else: Map.update!(file, kind, &MapSet.put(&1, item.part))

      key = {item.file_number, item.part}

      unresolved =
        if kind in [:confirmed, :repaired] do
          Map.delete(state.unresolved, key)
        else
          Map.put(state.unresolved, key, Map.put(item, :outcome, kind))
        end

      %{state | files: Map.put(state.files, item.file_number, file), unresolved: unresolved}
    else
      state
    end
  end

  # The checker calls this only after every check and any repair have finished.
  # Retain failures, but replace per-part accounting with upload-wide totals.
  def finish_file(state, number) do
    if finished?(state, number) do
      state
    else
      {file, files} = Map.pop(state.files, number, empty_file())

      state = %{
        state
        | files: files,
          totals: add(state.totals, counts(file)),
          finished: MapSet.put(state.finished, number)
      }

      advance_frontier(state)
    end
  end

  def summary(state) do
    Enum.reduce(state.files, state.totals, fn {_number, file}, totals ->
      add(totals, counts(file))
    end)
  end

  def finished?(state, number),
    do: number <= state.frontier or MapSet.member?(state.finished, number)

  defp advance_frontier(state) do
    next = state.frontier + 1

    if MapSet.member?(state.finished, next) do
      advance_frontier(%{state | frontier: next, finished: MapSet.delete(state.finished, next)})
    else
      state
    end
  end

  defp empty_file, do: Map.new(@outcomes, &{&1, MapSet.new()})
  defp empty_totals, do: Map.new(@outcomes, &{&1, 0})

  defp counts(file) do
    Map.new(@outcomes, fn kind ->
      parts =
        if kind == :missing, do: MapSet.difference(file.missing, file.repaired), else: file[kind]

      {kind, MapSet.size(parts)}
    end)
  end

  defp add(left, right), do: Map.merge(left, right, fn _kind, a, b -> a + b end)
end
