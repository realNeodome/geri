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

  def upload(paths, opts) when is_binary(paths) do
    upload(
      [paths],
      opts
    )
  end

  def upload(paths, opts) when is_list(paths) do
    with {:ok, opts} <- Geri.Auth.resolve(opts),
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
        Geri.JobState.abort(job)
        GenServer.stop(job)
        GenServer.stop(control)
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
        GenServer.stop(queue)
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
    producer =
      Task.async(fn ->
        try do
          produce(queue, job, paths, opts)
        rescue
          error in Geri.Encoder.Source.SizeChangedError ->
            reason = {:source_size_changed, error.path, error.expected_size, error.actual_size}
            Geri.Queue.abort(queue, reason)
            {:error, reason}

          error in File.Error ->
            reason = {:file_read_failed, error.path, error.reason}
            Geri.Queue.abort(queue, reason)
            {:error, reason}
        end
      end)

    workers =
      for worker <- 1..connections do
        Task.async(fn ->
          post_worker(
            queue,
            job,
            worker,
            opts
          )
        end)
      end

    Geri.Control.put_context(opts[:control], %{producer: producer.pid, workers: Enum.map(workers, & &1.pid)})

    pending = Map.new([producer | workers], &{&1.ref, &1.pid})
    await_upload(pending, opts[:control], :ok)
  end

  defp await_upload(pending, _control, result) when map_size(pending) == 0, do: result
  defp await_upload(pending, control, result) do
    receive do
      {ref, task_result} when is_map_key(pending, ref) ->
        Process.demonitor(ref, [:flush])
        result =
          case {result, task_result} do
            {:ok, {:error, _} = error} ->
              # Cancel before waiting for peers, retaining the original failure.
              Geri.Control.cancel(control)
              error

            _ -> result
          end
        await_upload(Map.delete(pending, ref), control, result)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(pending, ref) ->
        exit({:upload_task_exited, reason})
    end
  end

  defp produce(
         queue,
         job,
         paths,
         opts
       ) do
    file_total =
      length(paths)

    result =
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

    case result do
      :ok ->
        Geri.Queue.close(
          queue
        )

        :ok

      {:error, reason} = error ->
        Geri.Queue.abort(
          queue,
          reason
        )

        error
    end
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

  defp post_worker(
         queue,
         job,
         worker,
         opts
       ) do
    worker_opts =
      Keyword.put(
        opts,
        :worker,
        worker
      )

    try do
      case post_loop(queue, job, nil, worker, worker_opts) do
        {:ok, conn} ->
          Geri.NNTP.quit(conn)
          :ok
        {:error, reason, conn} ->
          Geri.NNTP.quit(conn)
          {:error, reason}
      end
    after
      Geri.Control.release(opts[:control])
    end
  end

  defp post_loop(
         queue,
         job,
         conn,
         worker,
         opts
       ) do
    case Geri.Queue.next(
           queue
         ) do
      {:ok, {part, article}} ->
        case controlled_post(
               conn,
               part,
               article,
               worker,
               opts
             ) do
          {:ok, conn} ->
            groups =
              opts
              |> Keyword.fetch!(
                :newsgroups
              )
              |> normalize_groups()

            case Geri.JobState.complete_part(
                   job,
                   part,
                   article,
                   groups,
                   worker
                 ) do
              :ok ->
                Logger.info(
                  "worker #{worker} completed " <>
                    "#{article.message_id} #{part.subject}"
                )

                post_loop(
                  queue,
                  job,
                  conn,
                  worker,
                  opts
                )

              {:error, reason} ->
                Logger.error(
                  "worker #{worker} failed updating job state " <>
                    "#{article.message_id}: " <>
                    "#{inspect(reason)}"
                )

                Geri.Queue.abort(
                  queue,
                  reason
                )

                {:error,
                 reason,
                 conn}
            end

          {:error, reason, conn} ->
            Logger.error(
              "worker #{worker} failed posting " <>
                "#{article.message_id}: " <>
                "#{inspect(reason)}"
            )

            Geri.Queue.abort(
              queue,
              reason
            )

            {:error,
             reason,
             conn}
        end

      :done ->
        Logger.debug(
          "worker #{worker} finished"
        )

        {:ok, conn}

      {:error, reason} ->
        {:error,
         reason,
         conn}
    end
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

  defp controlled_post(conn, part, article, worker, opts, preflight \\ true) do
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
    case Geri.Control.checkout(control, conn) do
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

    with {:ok, _} <- Geri.Control.checkout(opts[:control], nil) do
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
    connections = Keyword.get(repair_opts, :repair_connections, 2)

    with :ok <- validate_connections(connections),
         {:ok, queue} <- Geri.Queue.start_link(connections * 2) do
      if repair_opts[:control], do: Geri.Control.register_queue(repair_opts[:control], queue)
      producer =
        Task.async(fn ->
          produce_repairs(
            queue,
            items,
            article_opts
          )
        end)

      workers =
        for worker <- 1..connections do
          Task.async(fn ->
            repair_worker(
              queue,
              job,
              worker,
              repair_opts
            )
          end)
        end

      results =
        [producer | workers]
        |> Task.await_many(:infinity)

      GenServer.stop(queue)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> :ok
        error -> error
      end
    end
  end

  defp produce_repairs(queue, items, article_opts) do
    result =
      items
      |> Enum.group_by(& &1.path)
      |> Enum.reduce_while(:ok, fn {_path, file_items}, :ok ->
        file_items = Enum.sort_by(file_items, & &1.offset)

        case produce_repair_file(queue, file_items, article_opts) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      :ok ->
        Geri.Queue.close(queue)
        :ok

      {:error, reason} = error ->
        Geri.Queue.abort(queue, reason)
        error
    end
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

  defp repair_worker(queue, job, worker, opts) do
    worker_opts = Keyword.put(opts, :worker, "R#{worker}")

    try do
      case repair_loop(queue, job, nil, worker, worker_opts) do
        {:ok, conn} ->
          Geri.NNTP.quit(conn)
          :ok
        {:error, reason, conn} ->
          Geri.NNTP.quit(conn)
          {:error, reason}
      end
    after
      Geri.Control.release(opts[:control])
    end
  end

  defp repair_loop(queue, job, conn, worker, opts) do
    case Geri.Queue.next(queue) do
      {:ok, {item, part, article}} ->
        case controlled_post(conn, part, article, "R#{worker}", opts, false) do
          {:ok, conn} ->
            Geri.JobState.repair_present(job, item, worker)
            Logger.info(
              "repair worker #{worker} completed #{article.message_id} #{part.subject}"
            )
            repair_loop(queue, job, conn, worker, opts)

          {:error, reason, conn} ->
            if reason == :cancelled do
              {:error, :cancelled, conn}
            else
              Geri.JobState.repair_failed(job, item, worker, reason)
              repair_loop(queue, job, conn, worker, opts)
            end
        end

      :done ->
        {:ok, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
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

      _check_host ->
        case Keyword.get(opts, :repair_host) do
          nil ->
            {:ok, opts}

          host ->
            tls = Keyword.get(opts, :repair_tls, :implicit)
            port = Keyword.get(opts, :repair_port) || default_port(tls)

            repair_opts = [
              host: host,
              port: port,
              tls: tls,
              username: Keyword.get(opts, :repair_username),
              password: Keyword.get(opts, :repair_password)
            ]

            repair_opts =
              case Keyword.get(opts, :repair_auth_file, Keyword.get(opts, :auth_file)) do
                nil -> repair_opts
                auth_file -> Keyword.put(repair_opts, :auth_file, auth_file)
              end

            case Geri.Auth.resolve(repair_opts) do
              {:ok, resolved} ->
                opts =
                  opts
                  |> Keyword.put(:repair_port, port)
                  |> Keyword.put(:repair_tls, tls)
                  |> maybe_put(:repair_username, Keyword.get(resolved, :username))
                  |> maybe_put(:repair_password, Keyword.get(resolved, :password))

                {:ok, opts}

              {:error, reason} ->
                {:error, {:repair_auth, reason}}
            end
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

  defp stop_checker(nil), do: :ok

  defp stop_checker(checker) do
    if Process.alive?(checker) do
      GenServer.stop(checker, :normal, :infinity)
    else
      :ok
    end
  end

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

    repair_username =
      if Keyword.has_key?(opts, :repair_host) do
        Keyword.get(opts, :repair_username)
      else
        Keyword.get(opts, :check_username)
      end

    repair_password =
      if Keyword.has_key?(opts, :repair_host) do
        Keyword.get(opts, :repair_password)
      else
        Keyword.get(opts, :check_password)
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
        username: repair_username,
        password: repair_password,
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

  defp stop_tui(nil), do: :ok
  defp stop_tui(pid), do: GenServer.stop(pid, :normal, :infinity)

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
