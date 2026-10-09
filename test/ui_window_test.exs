defmodule Geri.UIWindowTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "geri-ui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    paths = for number <- 1..10 do
      path = Path.join(dir, "source#{number}.bin")
      File.write!(path, "hello")
      path
    end
    {:ok, job} = Geri.JobState.start_link("ui-key", paths,
      from: "test@example.invalid", host: "localhost", newsgroups: ["test"])

    on_exit(fn ->
      if Process.alive?(job), do: GenServer.stop(job)
      File.rm_rf!(dir)
    end)
    %{job: job}
  end

  test "late completion cannot scroll backward and recreate a completed black row", %{job: job} do
    {part2, article2} = article(2)
    Geri.JobState.prepare_part(job, part2, article2)
    Geri.JobState.complete_part(job, part2, article2, ["test"], 1)
    {part5, article5} = article(5)
    Geri.JobState.prepare_part(job, part5, article5)
    {part6, article6} = article(6)
    Geri.JobState.prepare_part(job, part6, article6)
    before = Geri.JobState.snapshot(job)
    assert before.progress.active_file == 6
    refute Enum.any?(before.files, &(&1.number == 2))

    assert :ok = Geri.JobState.complete_part(job, part5, article5, ["test"], 1)
    after_completion = Geri.JobState.snapshot(job)
    assert after_completion.progress.active_file == 6
    assert Enum.map(after_completion.files, & &1.number) == Enum.map(before.files, & &1.number)
    assert after_completion.progress.posted_bytes == 10
    file5 = Enum.find(after_completion.files, &(&1.number == 5))
    assert file5.posted_bytes == 5
  end

  test "an evicted file can finish without returning to the visible window", %{job: job} do
    {part1, article1} = article(1)
    Geri.JobState.prepare_part(job, part1, article1)
    {part6, article6} = article(6)
    Geri.JobState.prepare_part(job, part6, article6)

    assert :ok = Geri.JobState.complete_part(job, part1, article1, ["test"], 1)
    snapshot = Geri.JobState.snapshot(job)
    assert snapshot.progress.active_file == 6
    assert snapshot.progress.posted_bytes == 5
    refute Enum.any?(snapshot.files, &(&1.number == 1))
    assert hd(snapshot.activity).file_number == 1
  end

  defp article(number) do
    part = %{
      file_number: number, file_total: 10, filename: "source#{number}.bin",
      file_size: 5, source_size: 5, source_hash: :crypto.hash(:sha256, "hello"),
      encoding: :uuencode, offset: 0, part: 1, total: 1,
      subject: "source#{number}.bin (1/1)"
    }
    {part, %{message_id: "<ui-#{number}@test.invalid>", data: "article\r\n"}}
  end
end
