defmodule Geri.VerificationTest do
  use ExUnit.Case, async: true

  alias Geri.Verification, as: V

  defp item(file, part),
    do: %{file_number: file, part: part, message_id: "<#{file}.#{part}@test>"}

  test "folding preserves totals and keeps only unresolved details" do
    state =
      V.new()
      |> V.record(:confirmed, item(1, 1))
      |> V.record(:missing, item(1, 2))
      |> V.record(:repaired, item(1, 2))
      |> V.record(:missing, item(1, 3))
      |> V.record(:repair_failed, Map.put(item(1, 3), :reason, :rejected))
      |> V.record(:inconclusive, Map.put(item(1, 4), :reason, :timeout))

    before = V.summary(state)
    folded = V.finish_file(state, 1)
    assert V.summary(folded) == before
    assert before == %{confirmed: 1, missing: 1, repaired: 1, repair_failed: 1, inconclusive: 1}
    assert folded.files == %{}
    assert folded.unresolved == state.unresolved
    assert Map.keys(folded.unresolved) |> Enum.sort() == [{1, 3}, {1, 4}]
  end

  test "out of order completion rejects late results and coalesces finished markers" do
    state = V.new() |> V.record(:confirmed, item(2, 1)) |> V.finish_file(2)
    assert state.frontier == 0
    assert V.record(state, :missing, item(2, 1)) == state
    assert V.finish_file(state, 2) == state
    state = state |> V.record(:confirmed, item(1, 1)) |> V.finish_file(1)
    assert state.frontier == 2
    assert MapSet.size(state.finished) == 0
    assert V.record(state, :repaired, item(1, 1)) == state
    assert V.summary(state).confirmed == 2
  end

  test "pending and repeated results cannot undo terminal results" do
    state = V.new() |> V.record(:pending, item(1, 1)) |> V.record(:confirmed, item(1, 1))
    assert V.record(state, :confirmed, item(1, 1)) == state
    assert V.record(state, :pending, item(1, 1)) == state
    assert state.unresolved == %{}
  end

  test "unfinished files retain pending details alongside folded totals" do
    state =
      V.new()
      |> V.record(:confirmed, item(1, 1))
      |> V.finish_file(1)
      |> V.record(:pending, item(2, 1))
      |> V.record(:confirmed, item(2, 2))

    assert V.summary(state).confirmed == 2
    assert state.unresolved[{2, 1}].outcome == :pending
    assert Map.has_key?(state.files, 2)
  end

  test "successful accounting storage does not grow with completed article count" do
    state =
      Enum.reduce(1..100, V.new(), fn file, state ->
        Enum.reduce(1..1000, state, fn part, state ->
          V.record(state, :confirmed, item(file, part))
        end)
        |> V.finish_file(file)
      end)

    assert V.summary(state).confirmed == 100_000
    assert state.files == %{}
    assert state.unresolved == %{}
    assert MapSet.size(state.finished) == 0
    assert state.frontier == 100
    assert :erts_debug.size(state) < 100
  end
end
