#!/usr/bin/env bash
# Builds the desktop gateway package that a desktop host (the HiFox app)
# downloads, unpacks and supervises on the user's machine.
#
# Usage: deploy/desktop/package.sh <os> <arch> <version> <outdir>
#   os:   darwin | linux | windows
#   arch: amd64 | arm64
#
# Writes <outdir>/tokenhub-desktop_<version>_<os>_<arch>.<tar.gz|zip> and the
# matching .sha256 (sha256sum format). The archive root holds the package
# content directly, without a top-level directory:
#
#   VERSION
#   bin/tokenhub[.exe]
#   frontend/            Next.js standalone server; the host provides Node.js
#   catalog/             model and provider catalogs, builtin plugins
#   LICENSE, README.md
#
# Unlike the native server release, the package carries no Node.js runtime:
# the host runs frontend/server.js with its own (Electron's ELECTRON_RUN_AS_NODE).
# The backend is pure Go and cross-compiles. The frontend ships a
# platform-specific sharp binary; when the build host differs from the target,
# the target's prebuilt sharp packages are fetched from the npm registry, so
# one machine can build every target.
#
# Environment:
#   SOURCE_DATE_EPOCH                  archive timestamps (default: last commit time)
#   TOKENHUB_DESKTOP_REUSE_FRONTEND=1  skip `npm ci && npm run build` when
#                                      frontend/.next/standalone already exists
set -Eeuo pipefail

if [ "$#" -ne 4 ]; then
  printf 'usage: %s <os> <arch> <version> <outdir>\n' "$0" >&2
  exit 2
fi

target_os="$1"
target_arch="$2"
version="$3"
out_dir="$4"

case "$target_os/$target_arch" in
  darwin/amd64 | darwin/arm64 | linux/amd64 | linux/arm64 | windows/amd64 | windows/arm64) ;;
  *)
    printf 'unsupported target %s/%s\n' "$target_os" "$target_arch" >&2
    exit 2
    ;;
esac
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  printf 'version must be semantic (without a v prefix), got %q\n' "$version" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../local/standalone-bundle.sh
. "$repo_root/deploy/local/standalone-bundle.sh"

exe_suffix=""
archive_ext="tar.gz"
if [ "$target_os" = "windows" ]; then
  exe_suffix=".exe"
  archive_ext="zip"
fi
# sharp names its per-platform packages after Node's process.platform/arch.
case "$target_os" in
  windows) node_platform="win32" ;;
  *) node_platform="$target_os" ;;
esac
case "$target_arch" in
  amd64) node_arch="x64" ;;
  *) node_arch="$target_arch" ;;
esac

asset="tokenhub-desktop_${version}_${target_os}_${target_arch}.${archive_ext}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenhub-desktop.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
stage="$work_dir/stage"
mkdir -p "$stage/bin" "$stage/catalog"

log() {
  printf '[desktop-package] %s\n' "$*" >&2
}

fail() {
  printf '[desktop-package] ERROR: %s\n' "$*" >&2
  exit 1
}

# Prints the machine architecture of a Mach-O, ELF or PE binary as amd64 or
# arm64. Reads the headers directly so the check does not depend on file(1),
# which Windows runners may lack.
binary_arch() {
  local path="$1" magic machine pe_offset
  magic="$(od -An -tx1 -N4 "$path" | tr -d ' \n')"
  case "$magic" in
    cffaedfe)
      machine="$(od -An -tx1 -j4 -N4 "$path" | tr -d ' \n')"
      case "$machine" in
        07000001) echo amd64 ;;
        0c000001) echo arm64 ;;
        *) echo "mach-o:$machine" ;;
      esac
      ;;
    7f454c46)
      machine="$(od -An -tx1 -j18 -N2 "$path" | tr -d ' \n')"
      case "$machine" in
        3e00) echo amd64 ;;
        b700) echo arm64 ;;
        *) echo "elf:$machine" ;;
      esac
      ;;
    4d5a*)
      pe_offset="$(od -An -tu4 -j60 -N4 "$path" | tr -d ' \n')"
      machine="$(od -An -tx1 -j$((pe_offset + 4)) -N2 "$path" | tr -d ' \n')"
      case "$machine" in
        6486) echo amd64 ;;
        64aa) echo arm64 ;;
        *) echo "pe:$machine" ;;
      esac
      ;;
    *) echo "unknown:$magic" ;;
  esac
}

expect_binary() {
  local path="$1" actual
  [ -f "$path" ] || fail "missing binary $path"
  actual="$(binary_arch "$path")"
  [ "$actual" = "$target_arch" ] || fail "$path is built for $actual, expected $target_arch"
}

log "building backend for $target_os/$target_arch"
(
  cd "$repo_root/backend"
  CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" go build \
    -trimpath \
    -ldflags "-s -w -X main.buildVersion=${version} -X main.buildType=source -X main.deploymentType=source" \
    -o "$stage/bin/tokenhub${exe_suffix}" \
    ./cmd/tokenhub
)
expect_binary "$stage/bin/tokenhub${exe_suffix}"
chmod 0755 "$stage/bin/tokenhub${exe_suffix}"

if [ "${TOKENHUB_DESKTOP_REUSE_FRONTEND:-}" = "1" ] && [ -d "$repo_root/frontend/.next/standalone" ]; then
  log "reusing existing frontend build"
else
  log "building frontend"
  (
    cd "$repo_root/frontend"
    export NEXT_TELEMETRY_DISABLED=1
    npm ci --no-audit --no-fund
    npm run build
  )
fi
assemble_standalone_bundle "$repo_root/frontend" "$stage/frontend" || fail "frontend standalone bundle is incomplete"

# Next traces sharp into the standalone output for image optimization. npm
# installs only the host's optional sharp binary, so swap in the target's
# prebuilt packages (same versions sharp pins) and drop every other platform's.
img_dir="$stage/frontend/node_modules/@img"
sharp_dir="$img_dir/sharp-${node_platform}-${node_arch}"
if [ ! -d "$sharp_dir" ]; then
  sharp_manifest="$stage/frontend/node_modules/sharp/package.json"
  [ -f "$sharp_manifest" ] || fail "sharp is missing from the standalone bundle"
  wanted=("@img/sharp-${node_platform}-${node_arch}")
  # win32 packages bundle libvips; darwin/linux take it from a sibling package.
  [ "$node_platform" = "win32" ] || wanted+=("@img/sharp-libvips-${node_platform}-${node_arch}")
  fetch_dir="$work_dir/sharp-fetch"
  mkdir -p "$fetch_dir"
  for name in "${wanted[@]}"; do
    pkg_version="$(node -e 'const m=require(process.argv[1]);const v=(m.optionalDependencies||{})[process.argv[2]];if(!v)process.exit(1);process.stdout.write(v)' "$sharp_manifest" "$name")" ||
      fail "sharp does not list $name"
    log "fetching ${name}@${pkg_version} for $target_os/$target_arch"
    tarball="$(cd "$fetch_dir" && npm pack --silent "${name}@${pkg_version}" | tail -n 1)"
    dest="$img_dir/${name#@img/}"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xzf "$fetch_dir/$tarball" -C "$dest" --strip-components=1
  done
fi
for platform_dir in "$img_dir"/sharp-*; do
  [ -d "$platform_dir" ] || continue
  case "$(basename "$platform_dir")" in
    "sharp-${node_platform}-${node_arch}" | "sharp-libvips-${node_platform}-${node_arch}") ;;
    *) rm -rf "$platform_dir" ;;
  esac
done
sharp_binary="$(find "$sharp_dir" -type f -name '*.node' -print -quit 2>/dev/null || true)"
[ -n "$sharp_binary" ] || fail "missing sharp binary under ${sharp_dir#"$stage/"}; build on a ${target_os}/${target_arch} machine"
expect_binary "$sharp_binary"
while IFS= read -r native_module; do
  expect_binary "$native_module"
done < <(find "$stage/frontend" -type f -name '*.node' -print)

cp "$repo_root/data/model-catalog.yaml" "$stage/catalog/model-catalog.yaml"
cp "$repo_root/data/provider-catalog.json" "$stage/catalog/provider-catalog.json"
cp -R "$repo_root/data/builtin-plugins" "$stage/catalog/builtin-plugins"
cp "$repo_root/LICENSE" "$repo_root/README.md" "$stage/"
printf '%s\n' "$version" >"$stage/VERSION"

for required in \
  VERSION \
  "bin/tokenhub${exe_suffix}" \
  frontend/server.js \
  frontend/package.json \
  catalog/model-catalog.yaml \
  catalog/provider-catalog.json \
  catalog/builtin-plugins/providers/openai/plugin.yaml \
  catalog/builtin-plugins/platform/tokenhub.sim.default/plugin.yaml \
  LICENSE \
  README.md; do
  [ -f "$stage/$required" ] || fail "package is missing $required"
done
[ -d "$stage/frontend/.next/static" ] || fail "package is missing frontend/.next/static"

link_path="$(find "$stage" -type l -print -quit)"
[ -z "$link_path" ] || fail "package contains a symbolic link: ${link_path#"$stage/"}"

# The host unpacks under %APPDATA%\<App>\tokenhub\versions\<version>\, which
# leaves well under 260 characters only if package paths stay short.
longest="$(cd "$stage" && find . -mindepth 1 | sed 's|^\./||' | awk '{ if (length($0) > max) { max = length($0); path = $0 } } END { printf "%d %s", max, path }')"
[ "${longest%% *}" -lt 180 ] || fail "package path is ${longest%% *} characters (limit 179): ${longest#* }"
log "longest package path: ${longest%% *} characters"

source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$repo_root" log -1 --format=%ct)}"
top_level=(VERSION bin frontend catalog LICENSE README.md)
archive="$out_dir/$asset"
rm -f "$archive" "$archive.sha256"

log "writing $asset"
if [ "$archive_ext" = "zip" ]; then
  if command -v 7z >/dev/null 2>&1; then
    (cd "$stage" && 7z a -tzip -mx=9 -bd -bso0 "$archive" "${top_level[@]}")
  else
    (cd "$stage" && zip -q -r -X -9 "$archive" "${top_level[@]}")
  fi
  # ZIP requires "/" separators and the host's extractor rejects "\". Read
  # the central directory with Node, which the frontend build already needs.
  node -e '
    const data = require("fs").readFileSync(process.argv[1]);
    const endOfCentralDirectory = data.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
    let offset = data.readUInt32LE(endOfCentralDirectory + 16);
    let entries = 0;
    while (data.readUInt32LE(offset) === 0x02014b50) {
      const nameLength = data.readUInt16LE(offset + 28);
      const name = data.toString("utf8", offset + 46, offset + 46 + nameLength);
      if (name.includes("\\") || name.startsWith("/")) throw new Error(`invalid zip entry name: ${name}`);
      offset += 46 + nameLength + data.readUInt16LE(offset + 30) + data.readUInt16LE(offset + 32);
      entries++;
    }
    if (entries === 0) throw new Error("zip archive has no entries");
  ' "$(if command -v cygpath >/dev/null 2>&1; then cygpath -m "$archive"; else printf '%s' "$archive"; fi)"
else
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    gnu_tar=tar
  elif command -v gtar >/dev/null 2>&1; then
    gnu_tar=gtar
  else
    gnu_tar=""
  fi
  if [ -n "$gnu_tar" ]; then
    "$gnu_tar" \
      --sort=name \
      --mtime="@${source_date_epoch}" \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -C "$stage" \
      -cf - \
      "${top_level[@]}" | gzip -9n >"$archive"
  else
    # bsdtar (macOS) has no --sort/--mtime: normalize timestamps on the
    # throwaway stage and pass a sorted entry list instead.
    touch_stamp="$(date -u -r "$source_date_epoch" +%Y%m%d%H%M.%S)"
    (cd "$stage" && find "${top_level[@]}" -exec touch -h -t "$touch_stamp" {} +)
    (cd "$stage" && find "${top_level[@]}" | LC_ALL=C sort) >"$work_dir/entries"
    COPYFILE_DISABLE=1 tar \
      --no-mac-metadata \
      --uid 0 --gid 0 --uname root --gname root \
      --no-recursion \
      -C "$stage" \
      -cf - \
      -T "$work_dir/entries" | gzip -9n >"$archive"
  fi
  tar -tzf "$archive" >/dev/null
fi

if command -v sha256sum >/dev/null 2>&1; then
  checksum="$(sha256sum "$archive" | awk '{print $1}')"
else
  checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
fi
printf '%s  %s\n' "$checksum" "$asset" >"$archive.sha256"
log "done: $archive"
