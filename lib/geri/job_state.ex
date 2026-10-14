defmodule Geri.JobState do
  use GenServer

  require Logger

  @activity_limit 64
  @ui_history 3
  @ui_lookahead 3
  @ui_filename_limit 32

  def start_link(upload_key, paths, opts) do
    # Link only after initialization succeeds, so an initialization error
    # is returned to ordinary callers without also sending an exit signal.
    case GenServer.start(__MODULE__, {upload_key, paths, opts}) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, pid}

      {:error, _reason} = error ->
        error
    end
  end

  def prepare_part(job, part, article) do
    GenServer.call(job, {:prepare_part, part, article}, :infinity)
  end

  def complete_part(job, part, article, groups, worker) do
    GenServer.call(job, {:complete_part, part, article, groups, worker}, :infinity)
  end

  def set_checker(job, checker) do
    GenServer.call(job, {:set_checker, checker})
  end

  def set_control(job, control), do: GenServer.call(job, {:set_control, control})

  def check_present(job, item, checker) do
    GenServer.cast(job, {:check_present, item, checker})
  end

  def check_not_found(job, item, checker) do
    GenServer.cast(job, {:check_not_found, item, checker})
  end

  def check_missing(job, item, checker) do
    GenServer.cast(job, {:check_missing, item, checker})
  end

  def check_inconclusive(job, item, checker, reason) do
    GenServer.cast(job, {:check_inconclusive, item, checker, reason})
  end

  def repair_present(job, item, worker) do
    GenServer.call(job, {:repair_present, item, worker}, :infinity)
  end

  def repair_failed(job, item, worker, reason) do
    GenServer.call(job, {:repair_failed, item, worker, reason}, :infinity)
  end

  # Asynchronous because posting can be waiting on Checker.enqueue/2.
  # Calls from the checker preserve ordering with its preceding result casts.
  def finish_verification_file(job, number) do
    GenServer.cast(job, {:finish_verification_file, number})
  end

  def verification(job), do: GenServer.call(job, :verification, :infinity)
  def result(job, repair_errors \\ []), do: GenServer.call(job, {:result, repair_errors}, :infinity)
  def failure_info(job), do: GenServer.call(job, :failure_info, :infinity)
  def snapshot(job), do: GenServer.call(job, :snapshot, :infinity)
  def finalize(job), do: GenServer.call(job, :finalize, :infinity)
  def abort(job), do: GenServer.call(job, :abort, :infinity)

  @impl true
  def init({upload_key, paths, opts}) do
    with {:ok, total_bytes} <- total_file_size(paths),
         {:ok, nzb} <- nzb_operation(fn -> open_nzb(opts) end) do
      state = %{
        job: %{
          key: upload_key,
          encoding: Keyword.get(opts, :encoding, Geri.defaults()[:encoding]),
          part_size: Keyword.get(opts, :part_size, Geri.defaults()[:part_size]),
          paths: paths,
          file_total: length(paths),
          total_bytes: total_bytes,
          started_at: System.monotonic_time(:millisecond),
          from: Geri.Header.display_from(Keyword.fetch!(opts, :from), Keyword.get(opts, :name)),
          comment: Keyword.get(opts, :comment),
          connections: Keyword.get(opts, :connections, Geri.defaults()[:connections]),
          checking_server: checking_server_config(opts),
          repair_server: repair_server_config(opts),
          checking_connections: Keyword.get(opts, :check_connections, 2)
        },
        posting: posting_config(opts),
        checker: nil,
        control: nil,
        verification: Geri.Verification.new(),
        recovery: %{files: %{}, completed_files: 0},
        nzb: build_nzb_state(nzb, length(paths)),
        ui: %{
          active_file: 1,
          posted_bytes: 0,
          checked_bytes: if(checking_server_config(opts), do: 0, else: nil),
          files: initial_ui_files(paths),
          activity: []
        }
      }

      Logger.debug("job state initialized key=#{upload_key} files=#{length(paths)}")
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:prepare_part, part, article}, _from, state) do
    state =
      state
      |> prepare_recovery_part(part, article)
      |> prepare_ui_part(part)

    {:reply, :ok, state}
  end

  def handle_call({:complete_part, part, article, groups, worker}, _from, state) do
    state =
      state
      |> complete_recovery_part(part)
      |> complete_ui_part(part, article, worker)
      |> record_nzb_part(part, article, groups)

    case flush_nzb(state) do
      {:ok, state} ->
        state =
          state
          |> purge_completed_recovery()
          |> trim_ui_window()

        {result, item} = maybe_enqueue_check(state, part, article)
        state = if item, do: update_verification(state, :pending, item), else: state
        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_checker, checker}, _from, state) do
    state =
      state
      |> Map.put(:checker, checker)
      |> enable_ui_checking()

    {:reply, :ok, state}
  end

  def handle_call({:set_control, control}, _from, state) do
    {:reply, :ok, %{state | control: control}}
  end

  def handle_call(:verification, _from, state) do
    {:reply, verification_summary(state), state}
  end

  def handle_call(:failure_info, _from, state) do
    {:reply, failure_details(state), state}
  end

  def handle_call({:result, repair_errors}, _from, state) do
    summary = verification_summary(state)

    result = cond do
      repair_errors != [] or summary.missing > 0 or summary.repair_failed > 0 ->
        {:error, {:verification_failed, failure_details(state), repair_errors}}
      summary.inconclusive > 0 ->
        {:error, {:verification_inconclusive, failure_details(state)}}
      true -> :ok
    end

    {:reply, result, state}
  end

  def handle_call({:repair_present, item, worker}, _from, state) do
    state = record_verification(state, :repaired, item, &mark_repair_present(&1, item, worker))
    {:reply, :ok, state}
  end

  def handle_call({:repair_failed, item, worker, reason}, _from, state) do
    item = Map.put(item, :reason, reason)
    state = record_verification(state, :repair_failed, item, &add_repair_activity(&1, :repair_failed, item, worker))
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_state(state), state}
  end

  def handle_call(:finalize, _from, state)
      when state.recovery.completed_files != state.job.file_total or
             map_size(state.recovery.files) != 0 do
    {:reply, {:error, :upload_incomplete}, state}
  end

  def handle_call(:finalize, _from, state) do
    case flush_nzb(state) do
      {:ok, state} ->
        case finalize_nzb(state) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:abort, _from, state) do
    state = abort_nzb(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:finish_verification_file, number}, state) do
    state = %{state | verification: Geri.Verification.finish_file(state.verification, number)}
    {:noreply, state}
  end

  def handle_cast({:check_present, item, checker}, state) do
    state = record_verification(state, :confirmed, item, &mark_check_present(&1, item, checker))
    {:noreply, state}
  end

  def handle_cast({:check_not_found, item, checker}, state) do
    state = if Geri.Verification.accepts?(state.verification, :missing, item),
      do: add_check_activity(state, :not_found, item, checker), else: state
    {:noreply, state}
  end

  def handle_cast({:check_missing, item, checker}, state) do
    state = record_verification(state, :missing, item, &add_check_activity(&1, :missing, item, checker))
    {:noreply, state}
  end

  def handle_cast({:check_inconclusive, item, checker, reason}, state) do
    item = Map.put(item, :reason, reason)
    state = record_verification(state, :inconclusive, item, &add_check_activity(&1, :inconclusive, item, checker))
    {:noreply, state}
  end

  defp verification_summary(state), do: Geri.Verification.summary(state.verification)

  defp failure_details(state) do
    state
    |> verification_summary()
    |> Map.merge(%{
      upload_key: state.job.key,
      recovery: state.recovery,
      nzb: if(state.nzb, do: Map.drop(state.nzb, [:writer]), else: nil),
      unresolved: state.verification.unresolved |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    })
  end

  defp update_verification(state, kind, item) do
    %{state | verification: Geri.Verification.record(state.verification, kind, item)}
  end

  defp record_verification(state, kind, item, activity) do
    if Geri.Verification.accepts?(state.verification, kind, item) do
      state |> activity.() |> update_verification(kind, item)
    else
      state
    end
  end

  defp total_file_size(paths) do
    Enum.reduce_while(paths, {:ok, 0}, fn path, {:ok, total} ->
      case File.stat(path) do
        {:ok, stat} -> {:cont, {:ok, total + stat.size}}
        {:error, reason} -> {:halt, {:error, {:file_stat_failed, path, reason}}}
      end
    end)
  end

  defp prepare_recovery_part(state, part, article) do
    file =
      Map.get(state.recovery.files, part.file_number, %{
        file_number: part.file_number,
        path: Enum.at(state.job.paths, part.file_number - 1),
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

    put_in(state.recovery.files[part.file_number], file)
  end

  defp complete_recovery_part(state, part) do
    case Map.fetch(state.recovery.files, part.file_number) do
      :error ->
        state

      {:ok, file} ->
        file = %{file | unresolved: Map.delete(file.unresolved, part.part)}
        put_in(state.recovery.files[part.file_number], file)
    end
  end

  defp recovery_file_complete?(file) do
    file.total_parts != nil and
      file.next_part > file.total_parts and
      map_size(file.unresolved) == 0
  end

  defp purge_completed_recovery(state) do
    {completed, pending} =
      state.recovery.files
      |> Enum.split_with(fn {_number, file} -> recovery_file_complete?(file) end)

    recovery = %{state.recovery |
      files: Map.new(pending),
      completed_files: state.recovery.completed_files + length(completed)
    }
    %{state | recovery: recovery}
  end

  defp prepare_ui_part(state, part) do
    state = ensure_ui_window(state, part.file_number)
    update_ui_file(state, part.file_number, fn file ->
      %{file | filename: part.filename, total_bytes: part.file_size, total_parts: part.total}
    end)
  end

  defp complete_ui_part(state, part, article, worker) do
    state = ensure_ui_window(state, part.file_number)
    state = update_ui_file(state, part.file_number, fn file ->
      %{
        file
        | filename: part.filename,
          total_bytes: part.file_size,
          total_parts: part.total,
          posted_parts: min(file.posted_parts + 1, part.total),
          posted_bytes: min(file.posted_bytes + part.source_size, part.file_size)
      }
    end)
    state = update_in(state.ui.posted_bytes, &(&1 + part.source_size))

    event = %{
      kind: :posted,
      timestamp: Time.utc_now() |> Time.truncate(:second),
      worker: worker,
      file_number: part.file_number,
      file_total: part.file_total,
      filename: part.filename,
      part: part.part,
      part_total: part.total,
      message_id: article.message_id
    }

    activity = [event | state.ui.activity] |> Enum.take(@activity_limit)

    put_in(state.ui.activity, activity)
  end

  defp update_ui_file(state, number, update) do
    case Map.fetch(state.ui.files, number) do
      {:ok, file} -> put_in(state.ui.files[number], update.(file))
      :error -> state
    end
  end

  defp enable_ui_checking(state) do
    files =
      Map.new(state.ui.files, fn {number, file} ->
        {number,
         %{
           file
           | checked_bytes: file.checked_bytes || 0,
             checked_parts: file.checked_parts || 0
         }}
      end)

    state
    |> put_in([:ui, :checked_bytes], state.ui.checked_bytes || 0)
    |> put_in([:ui, :files], files)
  end

  defp maybe_enqueue_check(%{checker: nil}, _part, _article), do: {:ok, nil}

  defp maybe_enqueue_check(state, part, article) do
    path = Enum.at(state.job.paths, part.file_number - 1)

    item = %{
      file_number: part.file_number,
      file_total: part.file_total,
      file_size: part.file_size,
      filename: part.filename,
      path: path,
      encoding: part.encoding,
      subject: part.subject,
      part: part.part,
      part_total: part.total,
      source_size: part.source_size,
      source_hash: part.source_hash,
      offset: Map.fetch!(part, :offset),
      begin: Map.get(part, :begin),
      end: Map.get(part, :end),
      pcrc32: Map.get(part, :pcrc32),
      crc32: Map.get(part, :crc32),
      message_id: article.message_id
    }

    if Geri.Control.mode(state.control) == :cancelled do
      {:ok, nil}
    else
      {Geri.Checker.enqueue(state.checker, item), item}
    end
  end

  defp mark_check_present(state, item, checker) do
    state =
      if is_nil(state.ui.checked_bytes) do
        state
      else
        update_in(state.ui.checked_bytes, &(&1 + item.source_size))
      end

    state =
      case Map.fetch(state.ui.files, item.file_number) do
        :error ->
          state

        {:ok, file} ->
          checked_bytes =
            min(
              (file.checked_bytes || 0) + item.source_size,
              file.total_bytes || item.source_size
            )

          checked_parts =
            min((file.checked_parts || 0) + 1, file.total_parts || item.part_total)

          file = %{file | checked_bytes: checked_bytes, checked_parts: checked_parts}
          put_in(state.ui.files[item.file_number], file)
      end

    add_check_activity(state, :checked, item, checker)
  end

  defp mark_repair_present(state, item, worker) do
    state =
      if is_nil(state.ui.checked_bytes) do
        state
      else
        update_in(state.ui.checked_bytes, &(&1 + item.source_size))
      end

    state =
      case Map.fetch(state.ui.files, item.file_number) do
        :error ->
          state

        {:ok, file} ->
          checked_bytes =
            min(
              (file.checked_bytes || 0) + item.source_size,
              file.total_bytes || item.source_size
            )

          checked_parts =
            min((file.checked_parts || 0) + 1, file.total_parts || item.part_total)

          file = %{file | checked_bytes: checked_bytes, checked_parts: checked_parts}
          put_in(state.ui.files[item.file_number], file)
      end

    add_repair_activity(state, :repaired, item, worker)
  end

  defp add_repair_activity(state, kind, item, worker) do
    event = %{
      kind: kind,
      timestamp: Time.utc_now() |> Time.truncate(:second),
      worker: worker,
      file_number: item.file_number,
      file_total: item.file_total,
      filename: item.filename,
      part: item.part,
      part_total: item.part_total,
      message_id: item.message_id
    }

    activity = [event | state.ui.activity] |> Enum.take(@activity_limit)
    put_in(state.ui.activity, activity)
  end

  defp add_check_activity(state, kind, item, checker) do
    event = %{
      kind: kind,
      timestamp: Time.utc_now() |> Time.truncate(:second),
      checker: checker,
      file_number: item.file_number,
      file_total: item.file_total,
      filename: item.filename,
      part: item.part,
      part_total: item.part_total,
      message_id: item.message_id
    }

    activity = [event | state.ui.activity] |> Enum.take(@activity_limit)
    put_in(state.ui.activity, activity)
  end

  defp initial_ui_files(paths) do
    paths
    |> Enum.take(@ui_history + @ui_lookahead + 1)
    |> Enum.with_index(1)
    |> Map.new(fn {path, number} ->
      {number, new_ui_file(number, path)}
    end)
  end

  defp new_ui_file(number, path) do
    %{
      number: number,
      filename: Path.basename(path),
      total_bytes: file_size_or_nil(path),
      posted_bytes: 0,
      checked_bytes: nil,
      total_parts: nil,
      posted_parts: 0,
      checked_parts: nil
    }
  end

  defp file_size_or_nil(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  defp ensure_ui_window(state, active) do
    # A slower worker can finish an earlier file after the producer advances.
    # Never scroll back and recreate discarded progress rows with zero counts.
    active = max(active, state.ui.active_file)
    window_size = @ui_history + @ui_lookahead + 1
    ideal_start = active - @ui_history
    max_start = max(state.job.file_total - window_size + 1, 1)

    start_number =
      ideal_start
      |> max(1)
      |> min(max_start)

    end_number = min(start_number + window_size - 1, state.job.file_total)

    state =
      Enum.reduce(start_number..end_number, state, fn number, acc ->
        ensure_ui_file(acc, number)
      end)

    files =
      state.ui.files
      |> Enum.filter(fn {number, _file} ->
        number >= start_number and number <= end_number
      end)
      |> Map.new()

    state
    |> put_in([:ui, :active_file], active)
    |> put_in([:ui, :files], files)
  end

  defp trim_ui_window(state) do
    ensure_ui_window(state, state.ui.active_file)
  end

  defp ensure_ui_file(state, number) do
    if Map.has_key?(state.ui.files, number) do
      state
    else
      case Enum.at(state.job.paths, number - 1) do
        nil ->
          state

        path ->
          file = new_ui_file(number, path)

          file =
            if state.checker do
              %{file | checked_bytes: 0, checked_parts: 0}
            else
              file
            end

          put_in(state.ui.files[number], file)
      end
    end
  end

  defp record_nzb_part(%{nzb: nil} = state, _part, _article, _groups) do
    state
  end

  defp record_nzb_part(state, part, article, groups) do
    file =
      Map.get(
        state.nzb.pending_files,
        part.file_number,
        new_nzb_file(state, part, article)
      )

    subject =
      if part.part == 1 do
        Map.get(article, :subject) || part.subject
      else
        file.subject
      end

    groups_used =
      Enum.reduce(groups, file.groups_used, fn group, set ->
        MapSet.put(set, group)
      end)

    segment = %{
      bytes: byte_size(article.data),
      message_id: strip_message_id(article.message_id)
    }

    file = %{
      file
      | subject: subject,
        groups_used: groups_used,
        segments: Map.put(file.segments, part.part, segment)
    }

    nzb = %{
      state.nzb
      | pending_files:
          Map.put(
            state.nzb.pending_files,
            part.file_number,
            file
          )
    }

    Logger.debug(
      "NZB recorded segment #{part.file_number}:#{part.part}/#{part.total} #{article.message_id}"
    )

    %{state | nzb: nzb}
  end

  defp new_nzb_file(state, part, article) do
    %{
      file_number: part.file_number,
      filename: part.filename,
      total_parts: part.total,
      poster: Map.get(article, :from) || state.job.from,
      date: System.system_time(:second),
      subject: nil,
      groups_used: MapSet.new(),
      segments: %{}
    }
  end

  defp flush_nzb(%{nzb: nil} = state) do
    {:ok, state}
  end

  defp flush_nzb(state) do
    case Map.get(state.nzb.pending_files, state.nzb.next_file) do
      nil ->
        {:ok, state}

      file ->
        if nzb_file_complete?(file) do
          Logger.debug("NZB file #{file.file_number} complete; flushing")

          case nzb_operation(fn -> Geri.NZB.write_file(state.nzb.writer, file) end) do
            :ok ->
              nzb = %{
                state.nzb
                | next_file: state.nzb.next_file + 1,
                  pending_files: Map.delete(state.nzb.pending_files, state.nzb.next_file)
              }

              state
              |> Map.put(:nzb, nzb)
              |> flush_nzb()

            {:error, reason} ->
              {:error, reason, state}
          end
        else
          {:ok, state}
        end
    end
  end

  defp nzb_file_complete?(file) do
    file.subject != nil and map_size(file.segments) == file.total_parts
  end

  defp finalize_nzb(%{nzb: nil} = state) do
    {:ok, state}
  end

  defp finalize_nzb(state) do
    cond do
      state.nzb.next_file != state.nzb.file_total + 1 ->
        {:error, :nzb_incomplete, state}

      map_size(state.nzb.pending_files) != 0 ->
        {:error, :nzb_incomplete, state}

      true ->
        case nzb_operation(fn -> Geri.NZB.finalize(state.nzb.writer) end) do
          :ok ->
            nzb = %{state.nzb | writer: nil}
            {:ok, %{state | nzb: nzb}}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp abort_nzb(%{nzb: nil} = state) do
    state
  end

  defp abort_nzb(%{nzb: %{writer: nil}} = state) do
    state
  end

  defp abort_nzb(state) do
    Geri.NZB.abort(state.nzb.writer)
    nzb = %{state.nzb | writer: nil}
    %{state | nzb: nzb}
  end

  defp open_nzb(opts) do
    case Keyword.get(opts, :nzb) do
      nil -> {:ok, nil}
      path -> Geri.NZB.open(path)
    end
  end

  # NZB's writer currently matches :ok on writes. Keep I/O errors in the
  # upload result rather than letting that match terminate JobState.
  defp nzb_operation(fun) do
    fun.()
  rescue
    error in MatchError -> {:error, {:nzb_write_failed, error.term}}
    error in ErlangError ->
      case error.original do
        :terminated -> {:error, {:nzb_write_failed, {:error, :terminated}}}
        _ -> reraise error, __STACKTRACE__
      end
  end

  defp build_nzb_state(nil, _file_total) do
    nil
  end

  defp build_nzb_state(writer, file_total) do
    %{
      writer: writer,
      path: writer.path,
      file_total: file_total,
      next_file: 1,
      pending_files: %{}
    }
  end

  defp checking_server_config(opts) do
    case Keyword.get(opts, :check_host) do
      nil ->
        nil

      host ->
        tls = Keyword.get(opts, :check_tls, :implicit)

        %{
          host: host,
          port: Keyword.get(opts, :check_port) || default_port(tls)
        }
    end
  end

  defp posting_config(opts) do
    tls = Keyword.get(opts, :tls, :implicit)

    %{
      host: Keyword.get(opts, :host),
      port: Keyword.get(opts, :port) || default_port(tls),
      tls: tls,
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      newsgroups: Keyword.get(opts, :newsgroups, [])
    }
  end

  defp default_port(:implicit), do: 563
  defp default_port(_tls), do: 119

  defp job_servers(state) do
    posting = %{
      host: state.posting.host,
      port: state.posting.port
    }

    case state.job.checking_server do
      nil ->
        [posting]

      checking ->
        repair = state.job.repair_server
        [posting, checking] ++ if(repair == checking, do: [], else: [repair])
    end
  end

  defp repair_server_config(opts) do
    case checking_server_config(opts) do
      nil -> nil
      checking ->
        tls = Keyword.get(opts, :repair_tls) || Keyword.get(opts, :check_tls, :implicit)
        port = Keyword.get(opts, :repair_port) ||
          if(Keyword.has_key?(opts, :repair_host), do: default_port(tls), else: checking.port)
        %{host: Keyword.get(opts, :repair_host) || checking.host, port: port}
    end
  end

  defp snapshot_state(state) do
    files =
      state.ui.files
      |> Enum.sort_by(fn {number, _file} -> number end)
      |> Enum.map(fn {_number, file} -> file end)

    {file_names, file_names_more} = snapshot_file_names(state)

    %{
      key: state.job.key,
      from: state.job.from,
      comment: state.job.comment,
      connections: state.job.connections,
      check_connections: state.job.checking_connections,
      file_total: state.job.file_total,
      file_names: file_names,
      file_names_more: file_names_more,
      posting: %{
        host: state.posting.host,
        port: state.posting.port,
        tls: state.posting.tls,
        newsgroups: state.posting.newsgroups
      },
      servers: job_servers(state),
      progress: %{
        active_file: state.ui.active_file,
        total_bytes: state.job.total_bytes,
        posted_bytes: state.ui.posted_bytes,
        checked_bytes: state.ui.checked_bytes,
        started_at: state.job.started_at
      },
      files: files,
      activity: state.ui.activity
    }
  end

  defp snapshot_file_names(state) do
    first_number = first_unflushed_file(state)

    remaining =
      max(
        state.job.file_total - first_number + 1,
        0
      )

    names =
      state.job.paths
      |> Enum.drop(first_number - 1)
      |> Enum.take(@ui_filename_limit)
      |> Enum.map(&Path.basename/1)

    {names, remaining > length(names)}
  end

  defp first_unflushed_file(%{nzb: nil} = state) do
    state.ui.active_file
  end

  defp first_unflushed_file(state) do
    min(state.nzb.next_file, state.job.file_total + 1)
  end

  defp strip_message_id(message_id) do
    message_id
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end
end
