defmodule Geri do
  require Logger

  @default_part_size 700 * 1024
  @default_connections 8
  @default_encoding :yenc

  def defaults do
    [
      part_size: @default_part_size,
      connections: @default_connections,
      tls: :implicit,
      encoding: @default_encoding
    ]
  end

  def generate_upload_key do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def upload(paths, opts) do
    with {:ok, paths, opts} <- Geri.Options.normalize(paths, opts),
         {:ok, opts} <- Geri.Auth.resolve(opts),
         {:ok, opts} <- resolve_check_auth(opts),
         {:ok, opts} <- resolve_repair_auth(opts) do
      do_upload(
        paths,
        opts
      )
    end
  end

  defp do_upload(paths, opts) do
    opts = Keyword.put(opts, :stat_before_post, Keyword.has_key?(opts, :upload_key))

    upload_key =
      Keyword.get_lazy(
        opts,
        :upload_key,
        fn ->
          generate_upload_key()
        end
      )

    connections =
      Keyword.get(
        opts,
        :connections,
        @default_connections
      )

    opts =
      Keyword.put(
        opts,
        :upload_key,
        upload_key
      )

    Logger.info(
      "upload key: #{upload_key}"
    )

    Logger.info(
      "posting connections: #{connections}"
    )

    with :ok <- validate_connections(connections),
         {:ok, job} <- Geri.JobState.start_link(upload_key, paths, opts) do
      {:ok, control} = Geri.Control.start_link()
      Geri.JobState.set_control(job, control)
      opts = Keyword.put(opts, :control, control)
      Geri.Control.put_context(control, %{job: job, opts: redact_options(opts)})
      if signal_handler = Keyword.get(opts, :signal_handler), do: Geri.Signals.attach(signal_handler, control)

      try do
        run_job(job, paths, connections, opts)
      after
        if signal_handler = Keyword.get(opts, :signal_handler), do: Geri.Signals.attach(signal_handler, nil)
        cleanup(fn -> Geri.JobState.abort(job) end)
        stop_process(job)
        stop_process(control)
      end
    end
  end

  defp run_job(job, paths, connections, opts) do
    with {:ok, queue} <- Geri.Queue.start_link(connections * 2) do
      control = Keyword.fetch!(opts, :control)
      Geri.Control.register_queue(control, queue)
      Geri.Control.put_context(control, %{queue: queue})
      try do
        with {:ok, checker} <- start_checker(job, opts) do
          Geri.Control.put_context(control, %{checker: checker})
          try do
            with :ok <- attach_checker(job, checker),
                 {:ok, tui} <- start_tui(job, opts) do
              try do
                complete_upload(queue, job, checker, paths, connections, opts)
              after
                stop_tui(tui)
              end
            end
          after
            stop_checker(checker)
          end
        end
      after
        stop_process(queue)
      end
    end
  end

  defp complete_upload(queue, job, checker, paths, connections, opts) do
    result = run_upload(queue, job, paths, connections, opts)
    result = if result == :ok and Geri.Control.mode(opts[:control]) == :cancelled,
      do: {:error, :cancelled}, else: result

    case result do
      :ok ->
        verification_result = finish_checker(checker)
        Geri.Control.await_idle(opts[:control])

        # Posting succeeded, so preserve the complete NZB even when checking
        # or repair failed. Capture unresolved details before stopping the job.
        finalization = if Geri.Control.mode(opts[:control]) == :cancelled,
          do: {:error, :cancelled}, else: Geri.JobState.finalize(job)
        case finalization do
          :ok ->
            case verification_result do
              :ok ->
                Logger.info("upload completed successfully")
                {:ok, Keyword.fetch!(opts, :upload_key)}

              {:error, {:verification_inconclusive, _details}} = error ->
                Logger.warning("upload completed; propagation verification inconclusive")
                error

              {:error, _reason} = error ->
                Logger.error("upload verification or repair failed")
                error
            end

          {:error, :cancelled} ->
            {:error, {:cancelled, Geri.JobState.failure_info(job)}}

          {:error, reason} ->
            Logger.error("job finalization failed: #{inspect(reason)}")
            {:error, {:finalization_failed, reason, Geri.JobState.failure_info(job)}}
        end

      {:error, :cancelled} ->
        Geri.Control.await_idle(opts[:control])
        stop_checker(checker)
        Logger.info("upload cancelled")
        {:error, {:cancelled, Geri.JobState.failure_info(job)}}

      {:error, reason} ->
        Geri.Control.cancel(opts[:control])
        Geri.Control.await_idle(opts[:control])
        stop_checker(checker)
        Logger.error("upload failed: #{inspect(reason)}")
        {:error, {:upload_failed, reason, Geri.JobState.failure_info(job)}}
    end
  end

  defp run_upload(
         queue,
         job,
         paths,
         connections,
         opts
       ) do
    run_batch(queue, job, connections, opts, :posting, fn ->
      try do
        produce(queue, job, paths, opts)
      rescue
        error in Geri.Encoder.Source.SizeChangedError ->
          reason = {:source_size_changed, error.path, error.expected_size, error.actual_size}
          {:error, reason}

        error in File.Error ->
          reason = {:file_read_failed, error.path, error.reason}
          {:error, reason}
      end
    end)
  end

  defp run_batch(queue, job, connections, opts, role, produce) do
    # The supervisor owns task lifetimes; monitors report crashes to this owner
    # without letting a task's exit signal kill it before cleanup and reporting.
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      producer = Task.Supervisor.async_nolink(supervisor, fn ->
        finish_production(queue, produce.())
      end)

      opts = if opts[:repair_notify], do: Keyword.put(opts, :repair_notify, producer.pid), else: opts

      workers =
        for worker <- 1..connections do
          task = Task.Supervisor.async_nolink(supervisor, fn ->
            posting_worker(queue, job, worker, opts, role)
          end)
          {task, {:worker, worker}}
        end

      if role == :posting do
        Geri.Control.put_context(opts[:control], %{
          producer: producer.pid,
          workers: Enum.map(workers, fn {task, _actor} -> task.pid end)
        })
      end

      pending = Map.new([{producer, :producer} | workers], fn {task, actor} ->
        {task.ref, {task, actor}}
      end)
      await_batch(pending, opts[:control], role, :ok)
    after
      cleanup(fn -> Supervisor.stop(supervisor, :normal, :infinity) end)
    end
  end

  defp finish_production(queue, :ok), do: Geri.Queue.close(queue)

  defp finish_production(queue, {:error, reason} = error) do
    Geri.Queue.abort(queue, reason)
    error
  end

  defp await_batch(pending, _control, _role, result) when map_size(pending) == 0, do: result

  defp await_batch(pending, control, role, result) do
    receive do
      {ref, task_result} when is_map_key(pending, ref) ->
        Process.demonitor(ref, [:flush])
        pending = Map.delete(pending, ref)

        case {result, task_result} do
          {:ok, {:error, _} = error} ->
            stop_batch(pending, control, role, error)

          _ ->
            await_batch(pending, control, role, result)
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(pending, ref) ->
        {{_task, actor}, pending} = Map.pop!(pending, ref)

        case result do
          :ok -> stop_batch(pending, control, role, {:error, {:task_exited, role, actor, reason}})
          _ -> await_batch(pending, control, role, result)
        end
    end
  end

  defp stop_batch(pending, control, :posting, error) do
    Geri.Control.cancel(control)
    await_batch(pending, control, :posting, error)
  end

  defp stop_batch(pending, control, :repair, {:error, :cancelled} = error) do
    # Wake a persistent repair producer waiting for its next batch or results.
    Enum.each(pending, fn {_ref, {task, _actor}} -> send(task.pid, {:cancelled, control}) end)
    # User cancellation retains Control's grace period for active operations.
    await_batch(pending, control, :repair, error)
  end

  defp stop_batch(pending, _control, :repair, error) do
    # A repair batch shares the upload's pause/cancel coordinator. Stop only
    # this batch's tasks; cancelling Control would also stop initial posting
    # and replace the repair failure with a user-cancellation outcome.
    # Task shutdown waits for each worker's death; owned sockets/files close
    # and Control's process monitors remove their actor registrations.
    Enum.each(pending, fn {_ref, {task, _actor}} -> Task.shutdown(task, :brutal_kill) end)
    error
  end

  defp produce(
         queue,
         job,
         paths,
         opts
       ) do
    file_total =
      length(paths)

    paths
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      :ok,
      fn {path, file_number}, :ok ->
        case produce_file(
               queue,
               job,
               path,
               file_number,
               file_total,
               opts
             ) do
          :ok ->
            {:cont, :ok}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end
    )
  end

  defp produce_file(
         queue,
         job,
         path,
         file_number,
         file_total,
         opts
       ) do
    part_size =
      Keyword.get(
        opts,
        :part_size,
        @default_part_size
      )

    encoding =
      Keyword.get(
        opts,
        :encoding,
        @default_encoding
      )

    Logger.info(
      "preparing #{path} " <>
        "[#{file_number}/#{file_total}]"
    )

    with {:ok, parts} <-
           stream_file(
             path,
             encoding,
             part_size
           ) do
      Enum.reduce_while(
        parts,
        :ok,
        fn part, :ok ->
          part =
            part
            |> Map.merge(%{
              file_number: file_number,
              file_total: file_total,
              offset: part_offset(part, encoding, part_size)
            })
            |> put_subject(
              opts
            )

          with :ok <- Geri.Control.await(opts[:control]),
               {:ok, article} <-
                 Geri.Article.build(
                   part,
                   opts
                 ),
               :ok <-
                 Geri.JobState.prepare_part(
                   job,
                   part,
                   article
                 ),
               :ok <-
                 Geri.Queue.push(
                   queue,
                   {part, article}
                 ) do
            {:cont, :ok}
          else
            {:error, _reason} = error ->
              {:halt, error}
          end
        end
      )
    end
  end

  defp posting_worker(queue, job, worker, opts, role) do
    label = if role == :repair, do: "R#{worker}", else: worker
    opts = Keyword.put(opts, :worker, label)

    try do
      case posting_loop(queue, job, nil, worker, opts, role) do
        {:ok, conn} ->
          Geri.NNTP.quit(conn)
          :ok

        {:error, reason, conn} ->
          Geri.NNTP.quit(conn)
          {:error, reason}
      end
    after
      cleanup(fn -> Geri.Control.release(opts[:control]) end)
    end
  end

  defp posting_loop(queue, job, conn, worker, opts, role) do
    case Geri.Queue.next(queue) do
      {:ok, queued} ->
        {part, article, item} = posting_item(role, queued)

        case controlled_post(conn, part, article, opts[:worker], opts, role == :posting) do
          {:ok, conn} ->
            case record_post(role, job, part, article, item, worker, opts) do
              :ok ->
                if notify = opts[:repair_notify], do: send(notify, :repair_item_finished)
                posting_loop(queue, job, conn, worker, opts, role)

              {:error, reason} ->
                Geri.Queue.abort(queue, reason)
                {:error, reason, conn}
            end

          {:error, reason, conn} ->
            case record_post_failure(role, job, item, article, worker, reason) do
              :ok ->
                if notify = opts[:repair_notify], do: send(notify, :repair_item_finished)
                posting_loop(queue, job, conn, worker, opts, role)

              {:error, reason} ->
                Geri.Queue.abort(queue, reason)
                {:error, reason, conn}
            end
        end

      :done ->
        Logger.debug("worker #{opts[:worker]} finished")
        {:ok, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp posting_item(:posting, {part, article}), do: {part, article, nil}
  defp posting_item(:repair, {item, part, article}), do: {part, article, item}

  defp record_post(:posting, job, part, article, _item, worker, opts) do
    groups = opts |> Keyword.fetch!(:newsgroups) |> normalize_groups()

    case Geri.JobState.complete_part(job, part, article, groups, worker) do
      :ok ->
        Logger.info("worker #{worker} completed #{article.message_id} #{part.subject}")
        :ok

      {:error, reason} = error ->
        Logger.error(
          "worker #{worker} failed updating job state #{article.message_id}: #{inspect(reason)}"
        )

        error
    end
  end

  defp record_post(:repair, job, part, article, item, worker, _opts) do
    :ok = Geri.JobState.repair_present(job, item, worker)
    Logger.info("repair worker #{worker} completed #{article.message_id} #{part.subject}")
    :ok
  end

  defp record_post_failure(_role, _job, _item, _article, _worker, :cancelled),
    do: {:error, :cancelled}

  defp record_post_failure(:posting, _job, _item, article, worker, reason) do
    Logger.error("worker #{worker} failed posting #{article.message_id}: #{inspect(reason)}")
    {:error, reason}
  end

  defp record_post_failure(:repair, job, item, _article, worker, reason) do
    Geri.JobState.repair_failed(job, item, worker, reason)
  end

  defp post_with_recovery(
         conn,
         part,
         article,
         worker,
         opts
       ) do
    post_opts =
      Keyword.put(
        opts,
        :message_id,
        article.message_id
      )

    case Geri.NNTP.post(
           conn,
           article.data,
           post_opts
         ) do
      :ok ->
        {:ok, conn}

      {:error,
       {:transport,
        :before_article,
        reason}} ->
        Logger.warning(
          "worker #{worker} connection lost before posting " <>
            "#{article.message_id}: " <>
            "#{inspect(reason)}"
        )

        reconnect_and_retry(
          conn,
          part,
          article,
          worker,
          opts,
          false
        )

      {:error,
       {:transport,
        :uncertain,
        reason}} ->
        Logger.warning(
          "worker #{worker} connection lost while posting " <>
            "#{article.message_id}: " <>
            "#{inspect(reason)}"
        )

        reconnect_and_retry(
          conn,
          part,
          article,
          worker,
          opts,
          true
        )

      {:error, {:post_rejected, _code, _message} = reason} ->
        case Geri.NNTP.stat(conn, article.message_id, opts) do
          :present ->
            Logger.info("worker #{worker} confirmed #{article.message_id} already present after posting rejection")
            {:ok, conn}

          :missing ->
            {:error, reason, conn}

          {:error, stat_reason} ->
            Logger.warning("worker #{worker} could not check #{article.message_id} after posting rejection: #{inspect(stat_reason)}")
            conn =
              case stat_reason do
                {:stat_failed, _code, _message} -> conn
                _ ->
                  Geri.NNTP.close(conn)
                  nil
              end
            {:error, reason, conn}
        end

      {:error, reason} ->
        {:error,
         reason,
         conn}
    end
  end

  defp controlled_post(conn, part, article, worker, opts, preflight) do
    network_step(conn, opts, fn conn ->
      if preflight do
        upload_part(conn, part, article, worker, opts)
      else
        post_with_recovery(conn, part, article, worker, opts)
      end
    end)
  end

  defp network_step(conn, opts, operation) do
    control = opts[:control]
    case Geri.Control.checkout(control, conn, opts[:worker]) do
      {:error, reason} -> {:error, reason, nil}
      {:ok, conn} ->
        result = with {:ok, conn} <- ensure_post_connection(conn, opts),
                      :ok <- Geri.Control.connected(control, conn) do
          operation.(conn)
        else
          {:error, reason} -> {:error, reason, nil}
        end
        case result do
          {:ok, conn} -> {:ok, Geri.Control.checkin(control, conn)}
          {:error, reason, conn} ->
            conn = Geri.Control.checkin(control, conn)
            {:error, reason, conn}
        end
    end
  end

  defp ensure_post_connection(nil, opts), do: connect(opts)
  defp ensure_post_connection(conn, _opts), do: {:ok, conn}

  defp upload_part(conn, part, article, worker, opts) do
    if Keyword.get(opts, :stat_before_post, false) do
      case Geri.NNTP.stat(conn, article.message_id, opts) do
        :present ->
          Logger.info("worker #{worker} found #{article.message_id} already present; skipping POST")
          {:ok, conn}

        :missing ->
          post_with_recovery(conn, part, article, worker, opts)

        {:error, {:stat_failed, _code, _message} = reason} ->
          Logger.warning("worker #{worker} could not check #{article.message_id} before posting: #{inspect(reason)}; attempting POST")
          post_with_recovery(conn, part, article, worker, opts)

        {:error, reason} ->
          Logger.warning("worker #{worker} lost the STAT response for #{article.message_id}: #{inspect(reason)}; reconnecting")
          reconnect_and_retry(conn, part, article, worker, opts, true)
      end
    else
      post_with_recovery(conn, part, article, worker, opts)
    end
  end

  defp reconnect_and_retry(
         old_conn,
         part,
         article,
         worker,
         opts,
         uncertain
       ) do
    Geri.NNTP.close(
      old_conn
    )

    Geri.Control.checkin(opts[:control], nil)
    case reconnect(worker, opts) do
      {:error, reason} -> {:error, reason, nil}
      {:ok, conn} -> retry_after_reconnect(conn, part, article, worker, opts, uncertain)
    end
  end

  defp retry_after_reconnect(conn, part, article, worker, opts, uncertain) do
    if uncertain do
      case Geri.NNTP.stat(
             conn,
             article.message_id,
             opts
           ) do
        :present ->
          Logger.info(
            "worker #{worker} confirmed " <>
              "#{article.message_id} already posted"
          )

          {:ok, conn}

        :missing ->
          Logger.debug(
            "worker #{worker} retrying " <>
              "#{article.message_id}"
          )

          post_with_recovery(
            conn,
            part,
            article,
            worker,
            opts
          )

        {:error, {:stat_failed, _code, _message} = reason} ->
          Logger.warning(
            "worker #{worker} could not verify " <>
              "#{article.message_id}: " <>
              "#{inspect(reason)}; retrying"
          )

          post_with_recovery(
            conn,
            part,
            article,
            worker,
            opts
          )

        {:error, reason} ->
          Logger.warning("worker #{worker} lost the verification response for #{article.message_id}: #{inspect(reason)}; reconnecting")
          reconnect_and_retry(conn, part, article, worker, opts, true)
      end
    else
      post_with_recovery(
        conn,
        part,
        article,
        worker,
        opts
      )
    end
  end

  defp reconnect(
         worker,
         opts
       ) do
    delay =
      Keyword.get(
        opts,
        :reconnect_delay,
        5_000
      )

    with {:ok, _} <- Geri.Control.checkout(opts[:control], nil, opts[:worker]) do
      Logger.warning("worker #{worker} reconnecting")
      case connect(opts) do
        {:ok, conn} ->
          case Geri.Control.connected(opts[:control], conn) do
            :ok ->
              Logger.info("worker #{worker} reconnected")
              {:ok, conn}
            {:error, reason} -> {:error, reason}
          end
        {:error, reason} ->
          Geri.Control.checkin(opts[:control], nil)
          Logger.warning("worker #{worker} reconnect failed: #{inspect(reason)}")
          with :ok <- Geri.Control.wait(opts[:control], delay) do
            reconnect(worker, opts)
          end
      end
    end
  end

  defp connect(opts) do
    with {:ok, conn} <-
           Geri.NNTP.connect(
             opts
           ),
         :ok <- Geri.Control.connected(opts[:control], conn) do
      case Geri.NNTP.authenticate(
             conn,
             Keyword.get(
               opts,
               :username
             ),
             Keyword.get(
               opts,
               :password
             ),
             opts
           ) do
        :ok ->
          {:ok, conn}

        {:error, _reason} = error ->
          Geri.NNTP.close(
            conn
          )

          error
      end
    end
  end

  defp normalize_groups(groups)
       when is_list(groups) do
    groups
  end

  defp normalize_groups(groups)
       when is_binary(groups) do
    groups
    |> String.split(
      ","
    )
    |> Enum.map(
      &String.trim/1
    )
    |> Enum.reject(
      &(&1 == "")
    )
  end

  defp stream_file(
         path,
         :uuencode,
         part_size
       ) do
    Geri.Encoder.UUEncode.stream_file(
      path,
      part_size
    )
  end

  defp stream_file(
         path,
         :base64,
         part_size
       ) do
    Geri.Encoder.Base64.stream_file(
      path,
      part_size
    )
  end

  defp stream_file(
         path,
         :yenc,
         part_size
       ) do
    Geri.Encoder.YEnc.stream_file(
      path,
      part_size
    )
  end

  defp stream_file(
         _path,
         encoding,
         _part_size
       ) do
    {:error,
     {:unsupported_encoding,
      encoding}}
  end

  defp part_offset(%{begin: begin_pos}, :yenc, _part_size)
       when is_integer(begin_pos) do
    begin_pos - 1
  end

  defp part_offset(part, :base64, part_size) do
    {:ok, effective_size} = Geri.Encoder.Base64.normalize_part_size(part_size)
    (part.part - 1) * effective_size
  end

  defp part_offset(part, :uuencode, part_size) do
    {:ok, effective_size} = Geri.Encoder.UUEncode.normalize_part_size(part_size)
    (part.part - 1) * effective_size
  end

  defp put_subject(
         %{encoding: :yenc} = part,
         opts
       ) do
    width =
      part.file_total
      |> Integer.to_string()
      |> String.length()

    file_number =
      part.file_number
      |> Integer.to_string()
      |> String.pad_leading(
        width,
        "0"
      )

    prefix =
      case Keyword.get(
             opts,
             :comment
           ) do
        nil ->
          ""

        "" ->
          ""

        comment ->
          comment <> " "
      end

    subject =
      "#{prefix}[#{file_number}/#{part.file_total}] - " <>
        "\"#{part.filename}\" yEnc " <>
        "(#{part.part}/#{part.total}) " <>
        "#{part.file_size}"

    %{part | subject: subject}
  end

  defp put_subject(
         part,
         _opts
       ) do
    part
  end


  def repair(items, job, repair_opts, article_opts) when is_list(items) do
    run_repairs(job, repair_opts, fn queue ->
      produce_repairs(queue, items, article_opts)
    end)
  end

  # The checker owns the lifetime; file batches share this queue and pool.
  @doc false
  def repair_session(items, job, repair_opts, article_opts, owner) do
    pool = self()
    repair_opts = Keyword.put(repair_opts, :repair_notify, true)
    run_repairs(job, repair_opts, fn queue ->
      produce_repair_batches(queue, items, article_opts, owner, pool)
    end)
  end

  defp run_repairs(job, repair_opts, produce) do
    connections = Keyword.get(repair_opts, :repair_connections, 2)

    with :ok <- validate_connections(connections),
         {:ok, queue} <- Geri.Queue.start_link(connections * 2) do
      if repair_opts[:control], do: Geri.Control.register_queue(repair_opts[:control], queue)
      try do
        run_batch(queue, job, connections, repair_opts, :repair, fn -> produce.(queue) end)
      after
        stop_process(queue)
      end
    end
  end

  defp produce_repair_batches(queue, items, article_opts, owner, pool) do
    with :ok <- produce_repairs(queue, items, article_opts),
         :ok <- await_repair_results(length(items)) do
      # Workers acknowledge only after updating JobState. It is now safe to
      # fold this file's verification results, even while the pool stays open.
      send(owner, {:repair_finished, pool, hd(items).file_number, self()})

      receive do
        {:repair, items} -> produce_repair_batches(queue, items, article_opts, owner, pool)
        :finish -> :ok
        {:cancelled, _control} -> {:error, :cancelled}
      end
    end
  end

  defp await_repair_results(0), do: :ok

  defp await_repair_results(remaining) do
    receive do
      :repair_item_finished -> await_repair_results(remaining - 1)
      {:cancelled, _control} -> {:error, :cancelled}
    end
  end

  defp produce_repairs(queue, items, article_opts) do
    items
    |> Enum.group_by(& &1.path)
    |> Enum.reduce_while(:ok, fn {_path, file_items}, :ok ->
      file_items = Enum.sort_by(file_items, & &1.offset)

      case produce_repair_file(queue, file_items, article_opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp produce_repair_file(queue, [first | _] = items, article_opts) do
    case :file.open(first.path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          Enum.reduce_while(items, :ok, fn item, :ok ->
            case :file.pread(io, item.offset, item.source_size) do
              {:ok, binary} when byte_size(binary) == item.source_size ->
                with :ok <- Geri.Control.await(article_opts[:control]),
                     :ok <- verify_repair_source(binary, item),
                     part = repair_part(item, binary),
                     {:ok, article} <- Geri.Article.build(part, article_opts),
                     :ok <- verify_repair_message_id(article, item.message_id),
                     :ok <- Geri.Queue.push(queue, {item, part, article}) do
                  {:cont, :ok}
                else
                  {:error, _reason} = error -> {:halt, error}
                end

              {:ok, _short} ->
                {:halt, {:error, {:repair_short_read, item.path, item.offset}}}

              :eof ->
                {:halt, {:error, {:repair_eof, item.path, item.offset}}}

              {:error, reason} ->
                {:halt, {:error, {:repair_read_failed, item.path, reason}}}
            end
          end)
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, {:repair_open_failed, first.path, reason}}
    end
  end

  defp repair_part(%{encoding: :yenc} = item, binary) do
    body =
      Geri.Encoder.YEnc.encode_part(
        binary,
        item.filename,
        item.file_size,
        item.part,
        item.part_total,
        item.begin,
        item.end,
        item.pcrc32,
        item.crc32
      )

    item
    |> Map.take([
      :encoding,
      :filename,
      :part,
      :file_number,
      :file_total,
      :file_size
    ])
    |> Map.merge(%{
      total: item.part_total,
      source_hash: :crypto.hash(:sha256, binary),
      source_size: byte_size(binary),
      begin: item.begin,
      end: item.end,
      pcrc32: item.pcrc32,
      crc32: item.crc32,
      subject: item.subject,
      body: body
    })
  end

  defp repair_part(%{encoding: :base64} = item, binary) do
    item
    |> Map.take([
      :encoding,
      :filename,
      :part,
      :file_number,
      :file_total,
      :file_size
    ])
    |> Map.merge(%{
      total: item.part_total,
      source_hash: :crypto.hash(:sha256, binary),
      source_size: byte_size(binary),
      subject: item.subject,
      body: Geri.Encoder.Base64.encode(binary)
    })
  end

  defp repair_part(%{encoding: :uuencode} = item, binary) do
    item
    |> Map.take([
      :encoding,
      :filename,
      :part,
      :file_number,
      :file_total,
      :file_size
    ])
    |> Map.merge(%{
      total: item.part_total,
      source_hash: :crypto.hash(:sha256, binary),
      source_size: byte_size(binary),
      subject: item.subject,
      body:
        Geri.Encoder.UUEncode.encode_part(
          binary,
          item.filename,
          item.part,
          item.part_total
        )
    })
  end

  defp verify_repair_source(binary, item) do
    if :crypto.hash(:sha256, binary) == item.source_hash do
      :ok
    else
      {:error, {:repair_source_changed, item.path, item.part}}
    end
  end

  defp verify_repair_message_id(%{message_id: message_id}, message_id), do: :ok

  defp verify_repair_message_id(article, expected) do
    {:error, {:repair_message_id_mismatch, expected, article.message_id}}
  end

  defp resolve_check_auth(opts) do
    case Keyword.get(opts, :check_host) do
      nil ->
        {:ok, opts}

      host ->
        tls = Keyword.get(opts, :check_tls, :implicit)
        port = Keyword.get(opts, :check_port) || default_port(tls)

        check_opts = [
          host: host,
          port: port,
          tls: tls,
          username: Keyword.get(opts, :check_username),
          password: Keyword.get(opts, :check_password)
        ]

        check_opts =
          case Keyword.get(opts, :check_auth_file, Keyword.get(opts, :auth_file)) do
            nil -> check_opts
            auth_file -> Keyword.put(check_opts, :auth_file, auth_file)
          end

        case Geri.Auth.resolve(check_opts) do
          {:ok, resolved} ->
            opts =
              opts
              |> Keyword.put(:check_port, port)
              |> Keyword.put(:check_tls, tls)
              |> maybe_put(:check_username, Keyword.get(resolved, :username))
              |> maybe_put(:check_password, Keyword.get(resolved, :password))

            {:ok, opts}

          {:error, reason} ->
            {:error, {:check_auth, reason}}
        end
    end
  end

  defp resolve_repair_auth(opts) do
    case Keyword.get(opts, :check_host) do
      nil ->
        {:ok, opts}

      check_host ->
        separate = not is_nil(opts[:repair_host])
        host = opts[:repair_host] || check_host
        tls = opts[:repair_tls] || if(separate, do: :implicit, else: opts[:check_tls])
        port = opts[:repair_port] || if(separate, do: default_port(tls), else: opts[:check_port])
        inherit = not separate and port == opts[:check_port] and
          is_nil(opts[:repair_username]) and is_nil(opts[:repair_password]) and
          not Keyword.has_key?(opts, :repair_auth_file)

        repair_opts = [host: host, port: port, tls: tls,
          username: opts[:repair_username], password: opts[:repair_password]]
        default_auth_file = if separate, do: opts[:auth_file],
          else: Keyword.get(opts, :check_auth_file, opts[:auth_file])
        repair_opts = case Keyword.get(opts, :repair_auth_file, default_auth_file) do
          nil -> repair_opts
          auth_file -> Keyword.put(repair_opts, :auth_file, auth_file)
        end

        result = if inherit do
          {:ok, [username: opts[:check_username], password: opts[:check_password]]}
        else
          Geri.Auth.resolve(repair_opts)
        end

        case result do
          {:ok, resolved} ->
            {:ok, opts
              |> Keyword.put(:repair_port, port)
              |> Keyword.put(:repair_tls, tls)
              |> maybe_put(:repair_username, resolved[:username])
              |> maybe_put(:repair_password, resolved[:password])}

          {:error, reason} ->
            {:error, {:repair_auth, reason}}
        end
    end
  end

  defp start_checker(job, opts) do
    case Keyword.get(opts, :check_host) do
      nil ->
        {:ok, nil}

      _host ->
        Geri.Checker.start_link(
          job,
          checker_options(opts)
        )
    end
  end

  defp attach_checker(_job, nil), do: :ok
  defp attach_checker(job, checker), do: Geri.JobState.set_checker(job, checker)

  defp finish_checker(nil), do: :ok
  defp finish_checker(checker), do: Geri.Checker.finish(checker)

  defp stop_checker(checker), do: stop_process(checker)

  defp checker_options(opts) do
    repair_host = Keyword.get(opts, :repair_host) || Keyword.fetch!(opts, :check_host)
    repair_tls = Keyword.get(opts, :repair_tls) || Keyword.get(opts, :check_tls, :implicit)

    repair_port =
      Keyword.get(opts, :repair_port) ||
        if Keyword.has_key?(opts, :repair_host) do
          default_port(repair_tls)
        else
          Keyword.fetch!(opts, :check_port)
        end

    repair_reader =
      if Keyword.has_key?(opts, :repair_host) do
        Keyword.get(opts, :repair_reader, false)
      else
        Keyword.get(opts, :check_reader, false)
      end

    repair_tls_verify =
      if Keyword.has_key?(opts, :repair_host) do
        Keyword.get(opts, :repair_tls_verify, :peer)
      else
        Keyword.get(opts, :check_tls_verify, :peer)
      end

    repair_tls_ca_file =
      if Keyword.has_key?(opts, :repair_host) do
        Keyword.get(opts, :repair_tls_ca_file)
      else
        Keyword.get(opts, :check_tls_ca_file)
      end

    [
      control: opts[:control],
      host: Keyword.fetch!(opts, :check_host),
      port: Keyword.fetch!(opts, :check_port),
      tls: Keyword.get(opts, :check_tls, :implicit),
      tls_verify: Keyword.get(opts, :check_tls_verify, :peer),
      tls_ca_file: Keyword.get(opts, :check_tls_ca_file),
      username: Keyword.get(opts, :check_username),
      password: Keyword.get(opts, :check_password),
      reader: Keyword.get(opts, :check_reader, false),
      connections: Keyword.get(opts, :check_connections, 2),
      repair_connections: Keyword.get(opts, :repair_connections, 2),
      repair_opts: [
        control: opts[:control],
        host: repair_host,
        port: repair_port,
        tls: repair_tls,
        tls_verify: repair_tls_verify,
        tls_ca_file: repair_tls_ca_file,
        username: Keyword.get(opts, :repair_username),
        password: Keyword.get(opts, :repair_password),
        reader: repair_reader,
        repair_connections: Keyword.get(opts, :repair_connections, 2),
        reconnect_delay: Keyword.get(opts, :reconnect_delay, 5_000)
      ],
      article_opts: opts,
      reconnect_delay: Keyword.get(opts, :reconnect_delay, 5_000)
    ]
  end

  defp default_port(:implicit), do: 563
  defp default_port(_tls), do: 119

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp start_tui(job, opts) do
    if Keyword.get(opts, :tui, false) do
      if Code.ensure_loaded?(Geri.Terminal) do
        apply(Geri.Terminal, :start_link, [job, opts[:control]])
      else
        {:error, :tui_not_available}
      end
    else
      {:ok, nil}
    end
  end

  defp stop_tui(pid), do: stop_process(pid)

  defp stop_process(nil), do: :ok
  defp stop_process(pid), do: cleanup(fn -> GenServer.stop(pid, :normal, :infinity) end)

  # Cleanup must not replace the operation's result or its original exception.
  defp cleanup(action) do
    try do
      action.()
    catch
      :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
      kind, reason ->
        Logger.warning("cleanup failed: " <> Exception.format(kind, reason, __STACKTRACE__))
        :ok
    end
  end

  defp redact_options(opts) do
    Enum.map(opts, fn
      {key, _value} when key in [:password, :check_password, :repair_password] -> {key, "[redacted]"}
      entry -> entry
    end)
  end

  defp validate_connections(connections)
       when is_integer(connections) and
              connections > 0 do
    :ok
  end

  defp validate_connections(
         _connections
       ) do
    {:error,
     :invalid_connections}
  end
end
