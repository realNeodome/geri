defmodule Geri.Verification do
  @moduledoc """
  Pure verification accounting owned and updated by `Geri.JobState`.

  Active files retain per-outcome part sets for deduplication. `unresolved`
  retains body-free check/repair metadata keyed by `{file_number, part}`;
  confirmed or repaired items no longer need that detailed record. Finished
  file sets are folded into `totals`, while a contiguous frontier and a set of
  out-of-order finished file numbers reject late events without one historical
  key per successful article. All file and part numbers are one-based.

  Outcomes describe a lifecycle, not mutually exclusive buckets: a part can
  first be missing, then repaired or repair-failed. Summary subtracts repaired
  parts from missing; repairs do not count as confirmations on the check server.
  Pending metadata is not an additional outcome counter.

  This module has no process, scheduling, or I/O. Its internal map is not a
  persisted format. The caller must establish that a file is finished before
  folding; this module does not infer completion from a quiet queue.
  """

  @type outcome :: :confirmed | :missing | :repaired | :repair_failed | :inconclusive
  @type counts :: %{
          confirmed: non_neg_integer(),
          missing: non_neg_integer(),
          repaired: non_neg_integer(),
          repair_failed: non_neg_integer(),
          inconclusive: non_neg_integer()
        }
  @type file_outcomes :: %{
          confirmed: MapSet.t(pos_integer()),
          missing: MapSet.t(pos_integer()),
          repaired: MapSet.t(pos_integer()),
          repair_failed: MapSet.t(pos_integer()),
          inconclusive: MapSet.t(pos_integer())
        }
  @type t :: %{
          totals: counts(),
          files: %{pos_integer() => file_outcomes()},
          unresolved: %{{pos_integer(), pos_integer()} => Geri.Checker.item()},
          frontier: non_neg_integer(),
          finished: MapSet.t(pos_integer())
        }

  @outcomes [:confirmed, :missing, :repaired, :repair_failed, :inconclusive]

  @spec new() :: t()
  def new do
    %{totals: empty_totals(), files: %{}, unresolved: %{}, frontier: 0, finished: MapSet.new()}
  end

  # Reject late events for folded files and duplicates of the same outcome.
  # A pending event must not recreate details after a terminal outcome exists;
  # different terminal kinds can still represent missing -> repaired progress.
  @spec accepts?(t(), :pending | outcome(), Geri.Checker.item()) :: boolean()
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

  @spec record(t(), :pending | outcome(), Geri.Checker.item()) :: t()
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
  @spec finish_file(t(), pos_integer()) :: t()
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

  # Totals contain only folded files. Add active-file counts at read time so
  # folding changes retention, not the public numbers visible to the caller.
  @spec summary(t()) :: counts()
  def summary(state) do
    Enum.reduce(state.files, state.totals, fn {_number, file}, totals ->
      add(totals, counts(file))
    end)
  end

  @spec finished?(t(), pos_integer()) :: boolean()
  def finished?(state, number),
    do: number <= state.frontier or MapSet.member?(state.finished, number)

  # Out-of-order finished markers only bridge gaps. Once contiguous, their
  # individual keys can disappear without allowing late results to revive them.
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
