#!/bin/sh
#
# Build binary Debian package of deco from the git repository.
#
# usage: build-deb.sh [REPO [REV]]
#   REPO - path to deco git repository (default: the one containing this script)
#   REV  - git revision to build (default: HEAD)
#
# Result: deco_<version>_<arch>.deb in the current directory.
#
set -e
umask 022

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${1:-$here/../..}" && pwd)
rev=${2:-HEAD}

maintainer="KajiSpb <kaji.spb@gmail.com>"
upstream=$(sed -n 's/^project(deco VERSION \([0-9.]*\).*/\1/p' "$repo/CMakeLists.txt")
commit=$(git -C "$repo" rev-parse --short "$rev")
date=$(git -C "$repo" log -1 --format=%cd --date=format:%Y%m%d "$rev")
version="$upstream+git$date.$commit-1"
arch=$(dpkg --print-architecture)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src=$work/src
pkg=$work/pkg
mkdir -p "$src" "$pkg"

git -C "$repo" archive "$rev" | tar -x -C "$src"

# Do not force special "dim" color for root: let ~/.decoini palette apply.
sed -i '/^    if (uid == 0)$/{N;/palette.dimfg = 6;/d}' "$src/main.c"
if grep -q 'palette.dimfg = 6' "$src/main.c"; then
    echo "cannot remove root color override in main.c" >&2
    exit 1
fi

# Warnings must not break a distribution build (fortify adds new ones).
sed -i 's/ -Werror//' "$src/CMakeLists.txt"

# Data files live in /usr/share/deco; /usr/local/lib/deco still overrides.
sed -i 's|"/usr/lib/deco/|"/usr/share/deco/|' "$src/ex.c" "$src/help.c"

# Debian build flags (hardening etc.)
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
CFLAGS="$(dpkg-buildflags --get CFLAGS) $(dpkg-buildflags --get CPPFLAGS)"
LDFLAGS=$(dpkg-buildflags --get LDFLAGS)

cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" >/dev/null
make -C "$src/build" --no-print-directory
make -C "$src/build" --no-print-directory install DESTDIR="$pkg" >/dev/null
strip --remove-section=.comment --remove-section=.note "$pkg/usr/bin/deco"

# Data: menu, profile and help in all languages.
rm -rf "$pkg/usr/lib/deco"
rmdir "$pkg/usr/lib" 2>/dev/null || true
install -d "$pkg/usr/share/deco/help"
install -m 644 "$src/menu" "$src/profile" "$pkg/usr/share/deco/"
install -m 644 "$src"/help/* "$pkg/usr/share/deco/help/"

# Manual pages.
gzip -9n "$pkg"/usr/share/man/man1/*.1

# Documentation.
doc=$pkg/usr/share/doc/deco
install -d "$doc"
install -m 644 "$src/README.txt" "$doc/"
{
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: deco"
    echo "Source: https://github.com/KajiSpb/deco"
    echo
    echo "Files: *"
    echo "Copyright: 1989-2023 Serge Vakulenko"
    echo "License: MIT"
    sed 's/^$/./; s/^/ /' "$src/LICENSE.txt"
} > "$doc/copyright"
{
    echo "deco ($version) unstable; urgency=medium"
    echo
    git -C "$repo" log --format='  * %s' "0792ba3..$rev"
    echo "  * Do not force special dim color for root."
    echo "  * Install data files to /usr/share/deco, help in all languages."
    echo
    echo " -- $maintainer  $(git -C "$repo" log -1 --format=%cD "$rev")"
} | gzip -9n > "$doc/changelog.Debian.gz"

# Package metadata.
install -d "$pkg/DEBIAN" "$work/debian"
printf 'Source: deco\n\nPackage: deco\nArchitecture: any\n' > "$work/debian/control"
depends=$(cd "$work" && dpkg-shlibdeps -O "$pkg/usr/bin/deco" 2>/dev/null |
    sed -n 's/^shlibs:Depends=//p')
if [ -z "$depends" ]; then
    echo "dpkg-shlibdeps failed" >&2
    exit 1
fi
size=$(du -sk --exclude=DEBIAN "$pkg" | cut -f1)
cat > "$pkg/DEBIAN/control" <<EOF
Package: deco
Version: $version
Architecture: $arch
Maintainer: $maintainer
Installed-Size: $size
Depends: $depends
Section: utils
Priority: optional
Homepage: https://github.com/KajiSpb/deco
Description: Demos Commander, a free Norton Commander clone
 Text-mode file manager with two panels, user menus, file type
 bindings, built-in viewer and editor.
 .
 This build displays and accepts UTF-8 file names in UTF-8 locale
 (Cyrillic characters are supported).
EOF
(cd "$pkg" && find usr -type f -exec md5sum {} + | sort -k2) > "$pkg/DEBIAN/md5sums"

out="$PWD/deco_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$pkg" "$out" >/dev/null
echo "$out"
