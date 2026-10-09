if System.get_env("GERI_TUI") != "false" do
  defmodule Geri.TUI.Logger do
    @file_handler :geri_file
    @log_file "log/geri.log"

    def suspend_console do
      with :ok <- ensure_file_logger() do
        case :logger.get_handler_config(:default) do
          {:ok, config} ->
            case :logger.remove_handler(:default) do
              :ok ->
                {:ok, config}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, _reason} ->
            {:ok, nil}
        end
      end
    end

    def restore_console(nil) do
      :ok
    end

    def restore_console(config) do
      module =
        Map.fetch!(
          config,
          :module
        )

      config =
        Map.drop(
          config,
          [
            :id,
            :module
          ]
        )

      case :logger.add_handler(
             :default,
             module,
             config
           ) do
        :ok ->
          :ok

        {:error, {:already_exist, :default}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end

    def ensure_file_logger do
      with :ok <-
             File.mkdir_p(Path.dirname(@log_file)) do
        case :logger.get_handler_config(@file_handler) do
          {:ok, _config} ->
            :ok

          {:error, _reason} ->
            add_file_logger()
        end
      end
    end

    def log_file do
      @log_file
    end

    defp add_file_logger do
      config = %{
        level: :debug,
        formatter:
          {:logger_formatter,
           %{
             single_line: true
           }},
        config: %{
          type: :file,
          file: String.to_charlist(@log_file),
          modes: [
            :append
          ],
          file_check: 1_000,
          filesync_repeat_interval: 1_000
        }
      }

      case :logger.add_handler(
             @file_handler,
             :logger_std_h,
             config
           ) do
        :ok ->
          :ok

        {:error, {:already_exist, @file_handler}} ->
          :ok

        {:error, reason} ->
          {:error, {:file_logger, reason}}
      end
    end
  end
end
