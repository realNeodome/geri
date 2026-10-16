#!/bin/sh
set -eu

usage() {
  echo 'Usage: ./install.sh [--prefix DIR] [--release DIR]'
  echo 'Defaults: --prefix /usr/local --release _build/prod/rel/geri'
  echo 'Installs a previously built release; does not compile or fetch dependencies.'
}
SOURCE=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
prefix=/usr/local
release=$SOURCE/_build/prod/rel/geri
while [ "$#" -gt 0 ]; do
  case $1 in
    --prefix|--release)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      case $1 in --prefix) prefix=$2 ;; --release) release=$2 ;; esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
case $prefix in /*) ;; *) echo 'install.sh: prefix must be an absolute path' >&2; exit 1 ;; esac
[ "$prefix" != / ] || { echo 'install.sh: prefix cannot be /' >&2; exit 1; }
[ -x "$release/bin/geri" ] && [ -d "$release/releases" ] && [ -d "$release/lib" ] || {
  echo "install.sh: built release not found at $release" >&2; exit 1;
}
release=$(CDPATH= cd -P "$release" && pwd)
mkdir -p "$prefix/bin" "$prefix/lib"
prefix=$(CDPATH= cd -P "$prefix" && pwd)
destination=$prefix/lib/geri
link=$prefix/bin/geri
[ "$release" != "$destination" ] || { echo 'install.sh: cannot install a release onto itself' >&2; exit 1; }
# One private directory holds both the installation lock and rollback data.
# Acquire it before inspecting paths another installer could be replacing.
stage=$prefix/lib/.geri-install.lock
if ! mkdir -m 700 "$stage"; then
  echo "install.sh: cannot acquire installation lock $stage" >&2
  echo 'Another installer may be running, or an interrupted installation needs recovery.' >&2
  exit 1
fi
installed=false
replacing=false
link_existed=false
rollback_failed() {
  echo "install.sh: rollback failed; installation lock and recovery files retained at $stage" >&2
  if [ -d "$stage/previous" ]; then
    echo "install.sh: previous release retained at $stage/previous" >&2
  fi
  exit 1
}
cleanup() {
  install_status=$?
  trap - EXIT
  trap '' INT TERM
  if [ "$installed" = false ]; then
    # The staged directory disappears atomically when the new release moves
    # into place. This also detects a signal arriving just after that move.
    if [ "$replacing" = true ] && [ ! -d "$stage/release" ]; then
      rm -rf "$destination" || rollback_failed
    fi
    if [ -d "$stage/previous" ]; then
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || rollback_failed
      mv "$stage/previous" "$destination" || rollback_failed
    fi
    if [ "$link_existed" = false ] && [ -L "$link" ] &&
       [ "$(readlink "$link")" = "$destination/geri.sh" ]; then
      rm "$link" || rollback_failed
    fi
  fi
  if ! rm -rf "$stage"; then
    echo "install.sh: cannot remove installation lock $stage" >&2
    exit 1
  fi
  exit "$install_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -e "$link" ] || [ -L "$link" ]; then
  [ -L "$link" ] && [ "$(readlink "$link")" = "$destination/geri.sh" ] || {
    echo "install.sh: refusing to replace unrelated command $link" >&2; exit 1;
  }
  link_existed=true
fi
if [ -e "$destination" ] || [ -L "$destination" ]; then
  [ ! -L "$destination" ] && [ -f "$destination/.geri-install" ] || {
    echo "install.sh: refusing to replace unrecognized directory $destination" >&2; exit 1;
  }
fi
mkdir "$stage/release"
cp -R "$release/." "$stage/release/"
cp "$SOURCE/geri.sh" "$stage/release/geri.sh"
chmod 755 "$stage/release/geri.sh"
mkdir -p "$stage/release/docs"
cp "$SOURCE/README.md" "$stage/release/README.md"
cp "$SOURCE/LICENSE" "$stage/release/LICENSE"
cp -R "$SOURCE/docs/." "$stage/release/docs/"
printf '%s\n' 'Installed by Geri install.sh' > "$stage/release/.geri-install"
replacing=true
if [ -d "$destination" ]; then mv "$destination" "$stage/previous"; fi
mv "$stage/release" "$destination"
if [ "$link_existed" = false ]; then ln -s "$destination/geri.sh" "$link"; fi
installed=true
echo "Installed $link"
echo 'Ensure its bin directory is in PATH. Stop existing Geri jobs before upgrading.'
