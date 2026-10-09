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
if [ -e "$link" ] || [ -L "$link" ]; then
  [ -L "$link" ] && [ "$(readlink "$link")" = "$destination/geri.sh" ] || {
    echo "install.sh: refusing to replace unrelated command $link" >&2; exit 1;
  }
fi
if [ -e "$destination" ] || [ -L "$destination" ]; then
  [ ! -L "$destination" ] && [ -f "$destination/.geri-install" ] || {
    echo "install.sh: refusing to replace unrecognized directory $destination" >&2; exit 1;
  }
fi
stage=$(mktemp -d "$prefix/lib/.geri-install.XXXXXX")
installed=false
cleanup() {
  if [ "$installed" = false ] && [ -d "$stage/previous" ] && [ ! -e "$destination" ]; then
    mv "$stage/previous" "$destination"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage/release"
cp -R "$release/." "$stage/release/"
cp "$SOURCE/geri.sh" "$stage/release/geri.sh"
chmod 755 "$stage/release/geri.sh"
mkdir -p "$stage/release/docs"
cp "$SOURCE/README.md" "$stage/release/README.md"
cp "$SOURCE/LICENSE" "$stage/release/LICENSE"
cp "$SOURCE/docs/"*.md "$stage/release/docs/"
printf '%s\n' 'Installed by Geri install.sh' > "$stage/release/.geri-install"
if [ -d "$destination" ]; then mv "$destination" "$stage/previous"; fi
mv "$stage/release" "$destination"
installed=true
ln -sf "$destination/geri.sh" "$link"
echo "Installed $link"
echo 'Ensure its bin directory is in PATH. Stop existing Geri jobs before upgrading.'
