defmodule Geri.Recovery do
  @moduledoc """
  Pure posting-recovery bookkeeping owned and updated by `Geri.JobState`.

  State is `%{files: files, completed_files: count}`. Each unfinished file
  retains its path, total parts, next-part frontier, and unresolved prepared
  parts keyed by one-based part number. Unresolved entries contain only the
  Message-ID and source hash, not article bodies or verification outcomes.

  Preparation advances the frontier before queue admission. Posting completion
  removes an unresolved entry, but retirement is a separate operation so
  JobState can preserve its ordering relative to NZB writes and error reporting.
  A file can retire only after all planned parts have been prepared and none
  remain unresolved. `completed_files` is a count, not a contiguous frontier;
  workers may finish different files out of order.

  The producer prepares each file once, in part order; completions may arrive
  out of order. The caller supplies the path and valid prepared-part metadata.
  This module does no file I/O, scheduling, source validation, or persistence.
  The map remains internal in-memory state, not an implemented durable resume
  format.
  """

  def new, do: %{files: %{}, completed_files: 0}

  # next_part is one past the highest prepared part, not the lowest unfinished
  # part. Unresolved entries preserve holes while workers finish out of order.
  def prepare_part(state, part, article, path) do
    file =
      Map.get(state.files, part.file_number, %{
        file_number: part.file_number,
        path: path,
        total_parts: part.total,
        next_part: 1,
        unresolved: %{}
      })

    unresolved =
      Map.put(file.unresolved, part.part, %{
        message_id: article.message_id,
        source_hash: part.source_hash
      })

    file = %{
      file
      | total_parts: part.total,
        next_part: max(file.next_part, part.part + 1),
        unresolved: unresolved
    }

    put_in(state.files[part.file_number], file)
  end

  def complete_part(state, part) do
    case Map.fetch(state.files, part.file_number) do
      :error ->
        state

      {:ok, file} ->
        file = %{file | unresolved: Map.delete(file.unresolved, part.part)}
        put_in(state.files[part.file_number], file)
    end
  end

  def retire_completed(state) do
    {completed, pending} =
      Enum.split_with(state.files, fn {_number, file} -> file_complete?(file) end)

    %{
      state
      | files: Map.new(pending),
        completed_files: state.completed_files + length(completed)
    }
  end

  # An empty files map alone also describes a job whose producer never ran.
  def complete?(state, file_total) do
    state.completed_files == file_total and map_size(state.files) == 0
  end

  defp file_complete?(file) do
    file.total_parts != nil and
      file.next_part > file.total_parts and
      map_size(file.unresolved) == 0
  end
end
