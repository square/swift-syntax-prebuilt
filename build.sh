#!/bin/bash

set -euo pipefail

# Builds and packages the SwiftSyntax prebuilt archive in two phases so the
# work can fan out across heterogeneous CI runners:
#
#   ./build.sh build      Per-TARGET_PLATFORM. Emits staging/<platform>.tar.gz.
#   ./build.sh package    Combines all per-platform staging tarballs into the
#                         final release archive with a select()'d BUILD.bazel.
#
# Required env (build):   SWIFT_SYNTAX_VERSION, RULES_SWIFT_VERSION, TARGET_PLATFORM
# Required env (package): SWIFT_SYNTAX_VERSION, RULES_SWIFT_VERSION
# Optional env: BUILD_NUMBER, APPLE_SUPPORT_VERSION, RULES_APPLE_VERSION, MACOS_VERSION
#
# Build phase expects apple/swift-syntax checked out at ./swift-syntax.

APPLE_SUPPORT_VERSION="${APPLE_SUPPORT_VERSION:-1.23.1}"
RULES_APPLE_VERSION="${RULES_APPLE_VERSION:-4.2.0}"
MACOS_VERSION="${MACOS_VERSION:-13.0}"

# Workaround for https://github.com/bazelbuild/bazel/pull/27014 on macOS 26+.
export USE_BAZEL_VERSION="${USE_BAZEL_VERSION:-8.4.2}"

mode="${1:-}"
case "$mode" in
build | package) ;;
*)
  echo "usage: $0 <build|package>" >&2
  exit 64
  ;;
esac

if [ -z "${SWIFT_SYNTAX_VERSION:-}" ]; then
  echo "error: SWIFT_SYNTAX_VERSION is required" >&2
  exit 64
fi

if [ -z "${RULES_SWIFT_VERSION:-}" ]; then
  echo "error: RULES_SWIFT_VERSION is required" >&2
  exit 64
fi

release_tag="$SWIFT_SYNTAX_VERSION"
if [ -n "${BUILD_NUMBER:-}" ]; then
  release_tag="$release_tag+$BUILD_NUMBER"
fi

archive_name="swift-syntax-$release_tag"
staging_root="$PWD/staging"

bazel_cpu_for_target() {
  case "$1" in
  macos-arm64) echo "darwin_arm64" ;;
  macos-x86_64) echo "darwin_x86_64" ;;
  linux-x86_64) echo "k8" ;;
  linux-arm64) echo "aarch64" ;;
  *)
    echo "error: unsupported TARGET_PLATFORM '$1'" >&2
    exit 64
    ;;
  esac
}

os_family_for_target() {
  case "$1" in
  macos-*) echo "darwin" ;;
  linux-*) echo "linux" ;;
  *)
    echo "error: unsupported TARGET_PLATFORM '$1'" >&2
    exit 64
    ;;
  esac
}

# Echoes the @platforms//os constraint name for a platform dir. The archive
# ships one slice per OS, so the generated select()s key on OS alone -- this
# matches any cpu within an OS (e.g. a macos_x86_64 target gets the macOS
# slice), mirroring the single-archive behavior consumers relied on before.
os_constraint_for_platform() {
  case "$1" in
  macos-*) echo "macos" ;;
  linux-*) echo "linux" ;;
  *)
    echo "error: unsupported platform '$1'" >&2
    exit 64
    ;;
  esac
}

do_build() {
  if [ -z "${TARGET_PLATFORM:-}" ]; then
    echo "error: TARGET_PLATFORM is required for build mode" >&2
    exit 64
  fi

  local cpu os_family platform_dir
  cpu=$(bazel_cpu_for_target "$TARGET_PLATFORM")
  os_family=$(os_family_for_target "$TARGET_PLATFORM")
  platform_dir="$staging_root/$TARGET_PLATFORM"

  rm -rf "$platform_dir"
  mkdir -p "$platform_dir"

  pushd swift-syntax >/dev/null

  # Stash the upstream config; idempotent for repeat runs.
  [ -f .bazelrc ] && mv .bazelrc .bazelrc.original
  [ -f MODULE.bazel ] && mv MODULE.bazel MODULE.bazel.original

  cat >./MODULE.bazel <<EOF
module(name = "swift-syntax", version = "$SWIFT_SYNTAX_VERSION", compatibility_level = 1)
bazel_dep(name = "apple_support", version = "$APPLE_SUPPORT_VERSION", repo_name = "build_bazel_apple_support")
bazel_dep(name = "rules_swift", version = "$RULES_SWIFT_VERSION", repo_name = "build_bazel_rules_swift")
bazel_dep(name = "rules_apple", version = "$RULES_APPLE_VERSION", repo_name = "build_bazel_rules_apple")
EOF

  local -a build_flags
  build_flags=(
    "--@build_bazel_rules_swift//swift:copt=-whole-module-optimization"
    "--@build_bazel_rules_swift//swift:exec_copt=-whole-module-optimization"
    "--compilation_mode=opt"
    "--cpu=$cpu"
    "--features=swift.emit_swiftinterface"
    "--features=swift.enable_library_evolution"
  )
  if [ "$os_family" = "darwin" ]; then
    build_flags+=(
      "--host_macos_minimum_os=$MACOS_VERSION"
      "--macos_minimum_os=$MACOS_VERSION"
    )
  fi

  # Use `bazel query` (load-phase only) for label discovery; cquery would
  # analyze the whole //... universe and fail on Apple-toolchain-only
  # sibling targets like //:SwiftCompilerPluginTest.ios on Linux. The
  # later --output=files cqueries are on specific labels, so they only
  # analyze what we actually need.
  local query_out
  query_out=$(bazel query "filter(_opt, //...)")
  if [ -z "$query_out" ]; then
    echo "error: query for _opt swift targets returned no results" >&2
    exit 1
  fi
  local -a labels
  labels=()
  while IFS= read -r line; do
    [ -z "$line" ] || labels+=("$line")
  done <<<"$query_out"

  query_out=$(bazel query "kind(cc_library, //...)")
  if [ -z "$query_out" ]; then
    echo "error: query for cc_library targets returned no results" >&2
    exit 1
  fi
  local -a c_deps
  c_deps=()
  while IFS= read -r line; do
    [ -z "$line" ] || c_deps+=("$line")
  done <<<"$query_out"

  # swift-corelibs-foundation isn't compiled with library evolution support,
  # so swift_libraries that import Foundation (notably _SwiftSyntaxTestSupport)
  # fail under `swift.enable_library_evolution` on Linux. Drop TestSupport
  # from the Linux prebuilt; consumers needing it can build from source.
  if [ "$os_family" = "linux" ]; then
    local -a filtered_labels filtered_c_deps
    filtered_labels=()
    for label in "${labels[@]}"; do
      case "$label" in
      *TestSupport*) ;;
      *) filtered_labels+=("$label") ;;
      esac
    done
    labels=("${filtered_labels[@]}")
    filtered_c_deps=()
    for dep in "${c_deps[@]}"; do
      case "$dep" in
      *TestSupport*) ;;
      *) filtered_c_deps+=("$dep") ;;
      esac
    done
    c_deps=("${filtered_c_deps[@]}")
  fi

  # Build swift_library and cc_library targets separately; combining them
  # exposes a transition mismatch where cc_library outputs land under iOS
  # configs inherited from upstream's ios_unit_test rules.
  bazel build "${labels[@]}" "${build_flags[@]}"
  bazel build "${c_deps[@]}" "${build_flags[@]}"

  local meta_file="$platform_dir/_targets.tsv"
  : >"$meta_file"
  local label non_opt_label module_name dependencies
  for label in "${labels[@]}"; do
    non_opt_label="${label%_opt}"
    module_name=$(buildozer "print name" "$non_opt_label")
    dependencies=$(buildozer "print deps" "$non_opt_label" | sed 's/^\[//' | sed 's/\]$//')
    if [ "$dependencies" = "(missing)" ]; then
      dependencies=""
    fi
    printf 'swift_import\t%s\t%s\n' "$module_name" "$dependencies" >>"$meta_file"
  done

  # `cquery --output=files` lists files for every config a target appears in,
  # including iOS transitions from upstream's ios_unit_test / ios_xctestrun_runner;
  # those paths are never produced by our `bazel build` above, so skip them.
  local outputs output
  outputs=$(bazel cquery "set(${labels[*]})" --output=files "${build_flags[@]}")
  outputs+=$'\n'$(bazel cquery "set(${c_deps[*]})" --output=files "${build_flags[@]}")
  for output in $outputs; do
    [ -f "$output" ] || continue
    case "$output" in
    # Drop the position-independent variant Linux toolchains emit alongside
    # `libX.a`; we only need the static archive for consumer linking.
    *.pic.a) ;;
    *.swiftinterface | *.a | *.swiftdoc)
      cp -R "$output" "$platform_dir/$(basename "$output")"
      ;;
    esac
  done

  # Same cquery feeds the metadata row and the staged include/ tree.
  local hdrs_dir="$platform_dir/_headers"
  rm -rf "$hdrs_dir"
  local dep name hdr hdr_path target_hdrs_dir
  for dep in "${c_deps[@]}"; do
    name=$(buildozer "print name" "$dep")
    local -a hdrs=()
    while IFS= read -r hdr; do
      [ -z "$hdr" ] || hdrs+=("$hdr")
    done < <(bazel cquery "$dep" --output=jsonproto "${build_flags[@]}" |
      jq -rc '.results[0].target.rule.attribute[] | select(.name == "hdrs").stringListValue | .[]?')

    printf 'cc_import\t%s\t%s\n' "$name" "${hdrs[*]}" >>"$meta_file"

    if [ "${#hdrs[@]}" -gt 0 ]; then
      target_hdrs_dir="$hdrs_dir/$name/include"
      mkdir -p "$target_hdrs_dir"
      for hdr in "${hdrs[@]}"; do
        hdr_path="${hdr#//:}"
        cp "$hdr_path" "$target_hdrs_dir/$(basename "$hdr_path")"
      done
    fi
  done

  popd >/dev/null

  # Fail fast if nothing landed; an empty staging tar breaks the package
  # phase in confusing ways downstream.
  if ! find "$platform_dir" -maxdepth 1 -type f \
    \( -name '*.a' -o -name '*.swiftinterface' -o -name '*.swiftdoc' \) \
    | grep -q .; then
    echo "error: no .a / .swiftinterface / .swiftdoc outputs landed in $platform_dir" >&2
    exit 1
  fi

  local platform_tar="$staging_root/${TARGET_PLATFORM}.tar.gz"
  tar -czf "$platform_tar" -C "$staging_root" "$TARGET_PLATFORM"
  echo "build: wrote $platform_tar"
}

# Echoes a Starlark `select({...})` mapping each platform to <platform>/<basename>.
# kind "list" wraps each value in [] (list attrs like swift_import.archives);
# kind "scalar" emits a bare string (single-label attrs like swiftdoc,
# swiftinterface, cc_import.static_library).
emit_select_for_basename() {
  local kind="$1" basename="$2"
  shift 2
  local plat os
  printf 'select({\n'
  for plat in "$@"; do
    os=$(os_constraint_for_platform "$plat")
    if [ "$kind" = "list" ]; then
      printf '        "@platforms//os:%s": ["%s/%s"],\n' "$os" "$plat" "$basename"
    else
      printf '        "@platforms//os:%s": "%s/%s",\n' "$os" "$plat" "$basename"
    fi
  done
  printf '    })'
}

do_package() {
  if [ ! -d "$staging_root" ]; then
    echo "error: $staging_root not found; run './build.sh build' on each TARGET_PLATFORM first" >&2
    exit 64
  fi

  local tar_file platform
  for tar_file in "$staging_root"/*.tar.gz; do
    [ -e "$tar_file" ] || continue
    platform=$(basename "$tar_file" .tar.gz)
    if [ ! -d "$staging_root/$platform" ]; then
      tar -xzf "$tar_file" -C "$staging_root"
    fi
  done

  local -a platforms
  platforms=()
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    platforms+=("$(basename "$dir")")
  done < <(find "$staging_root" -mindepth 1 -maxdepth 1 -type d | sort)
  if [ ${#platforms[@]} -eq 0 ]; then
    echo "error: no per-platform staging directories found in $staging_root" >&2
    exit 64
  fi

  # Dep graph is platform-invariant; any platform's manifest works.
  local meta_file="$staging_root/${platforms[0]}/_targets.tsv"
  if [ ! -f "$meta_file" ]; then
    echo "error: missing metadata file $meta_file" >&2
    exit 64
  fi

  rm -rf "$archive_name"
  mkdir -p "$archive_name"

  cat >"$archive_name/MODULE.bazel" <<EOF
module(
    name = "swift-syntax",
    version = "$SWIFT_SYNTAX_VERSION",
    compatibility_level = 1,
)

bazel_dep(
    name = "platforms",
    version = "0.0.8",
)

bazel_dep(
    name = "rules_cc",
    version = "0.2.14",
)

bazel_dep(
    name = "rules_swift",
    version = "$RULES_SWIFT_VERSION",
    max_compatibility_level = 3,
    repo_name = "build_bazel_rules_swift",
)
EOF

  cat >"$archive_name/BUILD.bazel" <<'EOF'
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_import")
load("@rules_cc//cc:cc_import.bzl", "cc_import")

# Generated by build.sh package; do not edit.
# Rules select() on @platforms//os: the archive ships one slice per OS.
EOF

  local kind name deps
  while IFS=$'\t' read -r kind name deps; do
    case "$kind" in
    swift_import)
      {
        printf '\nswift_import(\n'
        printf '    name = "%s",\n' "$name"
        printf '    module_name = "%s",\n' "$name"
        printf '    archives = '
        emit_select_for_basename list "lib${name}.a" "${platforms[@]}"
        printf ',\n'
        printf '    swiftdoc = '
        emit_select_for_basename scalar "${name}.swiftdoc" "${platforms[@]}"
        printf ',\n'
        printf '    swiftinterface = '
        emit_select_for_basename scalar "${name}.swiftinterface" "${platforms[@]}"
        printf ',\n'
        if [ -n "$deps" ]; then
          # buildozer emits bare, space-separated labels (`:X :Y`); convert
          # to Starlark string list (`":X", ":Y"`).
          local quoted_deps
          # shellcheck disable=SC2086  # intentional word split on $deps
          quoted_deps=$(printf '"%s", ' $deps)
          quoted_deps=${quoted_deps%, }
          printf '    deps = [%s],\n' "$quoted_deps"
        fi
        printf '    visibility = ["//visibility:public"],\n'
        printf ')\n'
        printf '\nalias(\n    name = "%s_opt",\n    actual = ":%s",\n    visibility = ["//visibility:public"],\n)\n' "$name" "$name"
      } >>"$archive_name/BUILD.bazel"
      ;;
    cc_import)
      # Headers are platform-agnostic; merge once at archive root.
      local src_hdrs="$staging_root/${platforms[0]}/_headers/$name/include"
      if [ -d "$src_hdrs" ]; then
        mkdir -p "$archive_name/$name/include"
        cp -R "$src_hdrs/." "$archive_name/$name/include/"
      fi
      {
        printf '\ncc_import(\n'
        printf '    name = "%s",\n' "$name"
        printf '    static_library = '
        emit_select_for_basename scalar "lib${name}.a" "${platforms[@]}"
        printf ',\n'
        if [ -d "$src_hdrs" ]; then
          printf '    hdrs = glob(["%s/include/*.h"]),\n' "$name"
        fi
        printf '    visibility = ["//visibility:public"],\n'
        printf ')\n'
      } >>"$archive_name/BUILD.bazel"
      ;;
    esac
  done <"$meta_file"

  local plat
  for plat in "${platforms[@]}"; do
    mkdir -p "$archive_name/$plat"
    find "$staging_root/$plat" -maxdepth 1 -type f \
      \( -name '*.a' -o -name '*.swiftinterface' -o -name '*.swiftdoc' \) \
      -exec cp {} "$archive_name/$plat/" \;
  done

  tar -czf "${archive_name}.tar.gz" "$archive_name"

  openssl dgst -sha256 -binary "${archive_name}.tar.gz" |
    openssl base64 -A |
    sed 's/^/sha256-/' >"${archive_name}.tar.gz.sha256"
  local sha256_checksum
  sha256_checksum=$(cat "${archive_name}.tar.gz.sha256")

  echo "package: wrote ${archive_name}.tar.gz (${sha256_checksum}) covering platforms: ${platforms[*]}"
}

case "$mode" in
build) do_build ;;
package) do_package ;;
esac
