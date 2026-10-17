defmodule Geri.Session do
  @moduledoc """
  Establishes and authenticates one connection for posting, checking, or repair.

  The caller must first check out its actor through `Geri.Control`, unless no
  Control process is supplied. `connect/1` performs NNTP connection setup,
  registers the established socket before authentication, and returns either
  `{:ok, conn}` or the original setup/registration/authentication error.

  Registration before AUTHINFO lets Control close a stalled authentication
  receive. A connection acquired after cancellation is closed by Control;
  authentication failures are closed here. Setup failures belong to `Geri.NNTP`.

  This helper does not check out/in, retry, perform STAT/POST, or decide an
  upload outcome. The caller remains responsible for its admission scope and
  the returned connection. In particular, successful authentication does not
  imply Control is still running: pause/cancel may have arrived during it.
  """

  def connect(opts) do
    with {:ok, conn} <- Geri.NNTP.connect(opts),
         :ok <- Geri.Control.connected(opts[:control], conn) do
      case Geri.NNTP.authenticate(conn, opts[:username], opts[:password], opts) do
        :ok ->
          {:ok, conn}

        {:error, _reason} = error ->
          Geri.NNTP.close(conn)
          error
      end
    end
  end
end
