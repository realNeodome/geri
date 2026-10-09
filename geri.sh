#!/bin/sh

# Follow links without GNU readlink -f; only the subshell changes directory.
launcher=$0
case $launcher in
  */*) ;;
  *) launcher=$(command -v "$launcher") || exit 1 ;;
esac
links=0
while [ -L "$launcher" ]; do
  links=$((links + 1))
  [ "$links" -le 40 ] || { echo "geri: launcher symlink loop" >&2; exit 1; }
  DIR=$(CDPATH= cd -P "$(dirname "$launcher")" && pwd) || exit 1
  target=$(readlink "$launcher") || exit 1
  case $target in
    /*) launcher=$target ;;
    *) launcher=$DIR/$target ;;
  esac
done
DIR=$(CDPATH= cd -P "$(dirname "$launcher")" && pwd) || exit 1
if [ -x "$DIR/bin/geri" ]; then
  release=$DIR/bin/geri
elif [ -x "$DIR/_build/prod/rel/geri/bin/geri" ]; then
  release=$DIR/_build/prod/rel/geri/bin/geri
else
  echo "geri: release not found beside launcher; build and install the release first" >&2
  exit 1
fi

# Raw-mode Ctrl-C is handled by the TUI. Outside raw mode, translate the
# shell's SIGINT into a signal Geri can handle without BEAM's break menu.
# Explicit stdin forwarding keeps the background release's TUI/IEx usable.
trap 'kill -TERM "$geri_pid" 2>/dev/null || :' INT TERM
GERI_SIGNAL_BRIDGE=1 ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+Bi" \
  "$release" eval \
  'case Application.ensure_all_started(:geri) do
     {:ok, _} -> Geri.CLI.main(System.argv())
     {:error, reason} -> raise "cannot start Geri: #{inspect(reason)}"
   end' "$@" <&0 &
geri_pid=$!

# wait can be interrupted by a trapped signal; continue waiting for the
# release to finish its cleanup rather than leaving it behind.
while :; do
  wait "$geri_pid"
  geri_status=$?
  kill -0 "$geri_pid" 2>/dev/null || break
done
exit "$geri_status"
