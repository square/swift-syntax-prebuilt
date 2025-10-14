#!/bin/bash

set -euo pipefail

# This script builds the SwiftSyntax prebuilt binaries and outputs the SHA256 checksum for the archive.
# NOTE: this script expects that the swift-syntax repository is checked out in the same directory as this script.
#
# Required environment variables:
#   - SWIFT_SYNTAX_VERSION: The version of SwiftSyntax to build.
#   - RULES_SWIFT_VERSION: The version of rules_swift to use for the archive MODULE.bazel file and override in the swift-syntax MODULE.bazel file.
#   - MACOS_VERSION: The minimum macOS version to target.
#
# Optional environment variables:
#   - APPLE_SUPPORT_VERSION: The version of apple_support to use to override in the swift-syntax MODULE.bazel file.
#   - RULES_APPLE_VERSION: The version of rules_apple to use to override in the swift-syntax MODULE.bazel file.
#   - BUILD_NUMBER: The build number to append to the release tag.

# Default values for optional environment variables.
APPLE_SUPPORT_VERSION="${APPLE_SUPPORT_VERSION:-1.23.1}"
RULES_APPLE_VERSION="${RULES_APPLE_VERSION:-4.2.0}"

# NOTE: required to workaround issues in macOS 26+ (https://github.com/bazelbuild/bazel/pull/27014)
export USE_BAZEL_VERSION="${USE_BAZEL_VERSION:-8.4.2}"

release_tag="$SWIFT_SYNTAX_VERSION"
if [ -n "${BUILD_NUMBER:-}" ]; then
  release_tag="$release_tag+$BUILD_NUMBER"
fi

archive_name="swift-syntax-$release_tag"

mkdir -p "$archive_name"

# Create the MODULE.bazel file which will be used to include SwiftSyntax as a bazel_dep via archive_override.
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
    name = "rules_swift",
    version = "$RULES_SWIFT_VERSION",
    max_compatibility_level = 3,
    repo_name = "build_bazel_rules_swift",
)
EOF

# Create the BUILD file which will be used to include the exposed targets.
cat >"$archive_name/BUILD.bazel" <<EOF
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_import")
EOF

# -- start swift-syntax build --
pushd swift-syntax

# Move the .bazelrc and MODULE.bazel files as we set our own versions and build flags in this script.
mv .bazelrc .bazelrc.original
mv MODULE.bazel MODULE.bazel.original

# Create our own `MODULE.bazel` file to override the versions defined in swift-syntax.
cat >"./MODULE.bazel" <<EOF
module(name = "swift-syntax", version = "$SWIFT_SYNTAX_VERSION", compatibility_level = 1)
bazel_dep(name = "apple_support", version = "$APPLE_SUPPORT_VERSION", repo_name = "build_bazel_apple_support")
bazel_dep(name = "rules_swift", version = "$RULES_SWIFT_VERSION", repo_name = "build_bazel_rules_swift")
bazel_dep(name = "rules_apple", version = "$RULES_APPLE_VERSION", repo_name = "build_bazel_rules_apple")
EOF

# TODO: remove this eventually
# swift-syntax 601.0.x does not properly declare the version marker target
# so we add it to the BUILD file manually.
if [ "$SWIFT_SYNTAX_VERSION" == "601.0.1" ]; then
  echo "NOTE: patching swift-syntax BUILD.bazel for version marker module in swift-syntax $SWIFT_SYNTAX_VERSION"
  cat >>"BUILD.bazel" <<EOF
swift_syntax_library(
    name = "SwiftSyntax601",
    srcs = glob(["Sources/VersionMarkerModules/SwiftSyntax601/**/*.swift"]),
    deps = [
    ],
)
EOF
fi

# Shared build flags:
#  - set the minimum macOS version to the version specified in the workflow input
#  - set the host macOS version to the version specified in the workflow input
#  - enable library evolution
build_flags=(
  "--@build_bazel_rules_swift//swift:copt=-whole-module-optimization"
  "--@build_bazel_rules_swift//swift:exec_copt=-whole-module-optimization"
  "--compilation_mode=opt"
  "--cpu=darwin_arm64"
  "--features=swift.emit_swiftinterface"
  "--features=swift.enable_library_evolution"
  "--host_macos_minimum_os=$MACOS_VERSION"
  "--macos_minimum_os=$MACOS_VERSION"
)

# Collect the labels for the targets that will be exported.
# Targets exported are those suffixed with `_opt`.
# The cquery output looks like: `//:SwiftBasicFormat_opt (5d78ae7)` and we take just the label.
labels=($(bazel cquery "filter(_opt, //...)" "${build_flags[@]}" | sed 's/ (.*//'))

# Some supporting targets, we need to expose these as well as they include headers.
c_deps=($(bazel cquery "kind(cc_library, //...)" "${build_flags[@]}" | sed 's/ (.*//' | uniq))

# Create the BUILD file for each of the swift-syntax targets.
for label in ${labels[@]}; do
  # Collect information about the target, we need deps to be propagated to downstream targets.
  non_opt_label=$(echo $label | sed 's/_opt$//')
  module_name=$(buildozer "print name" $non_opt_label)
  dependencies=$(buildozer "print deps" $non_opt_label | sed 's/^\[//' | sed 's/\]$//')

  echo -e "\nGenerating BUILD file content for Swift target: $label"
  echo -e "\tModule name: $module_name"
  echo -e "\tDependencies: $dependencies"

  # Create the `swift_import` target for this module.
  # Do this in the directory to make it easier to use buildozer with labels.
  pushd "../$archive_name"
  buildozer "new swift_import ${module_name}" //:__pkg__ >/dev/null 2>&1
  buildozer "set module_name \"${module_name}\"" //:${module_name} >/dev/null 2>&1
  buildozer "set visibility \"//visibility:public\"" //:${module_name} >/dev/null 2>&1
  buildozer "set archives  \"lib${module_name}.a\"" //:${module_name} >/dev/null 2>&1
  buildozer "set swiftdoc \"${module_name}.swiftdoc\"" //:${module_name} >/dev/null 2>&1
  buildozer "set swiftinterface \"${module_name}.swiftinterface\"" //:${module_name} >/dev/null 2>&1

  if [ -n "$dependencies" ]; then
    buildozer "set deps ${dependencies[*]}" //:${module_name} >/dev/null 2>&1
  fi

  # Create the alias `_opt` for the `swift_import` target that is used by some other modules.
  # Since these are prebuilt in a release configuration, they are always in "opt" mode.
  buildozer "new alias ${module_name}_opt" //:__pkg__ >/dev/null 2>&1
  buildozer "set actual :${module_name}" //:${module_name}_opt >/dev/null 2>&1
  buildozer "set visibility \"//visibility:public\"" //:${module_name}_opt >/dev/null 2>&1

  popd
done

# Create the `cc_import` targets for each of the support targets.
for dep in ${c_deps[@]}; do
  name="$(buildozer "print name" ${dep})"
  hdrs=()
  while read -r hdr; do
    hdrs+=("$hdr")
  done < <(bazel cquery "${dep}" --output=jsonproto | jq -rc '.results[0].target.rule.attribute[] | select(.name == "hdrs").stringListValue | .[]')

  # Copy any headers to the archive directory and set the header path relative to the archive directory.
  hdrs_base_path="${name}/include"
  hdrs_dir="../$archive_name/${hdrs_base_path}"
  if [ ${#hdrs[@]} -gt 0 ]; then
    mkdir -p "$hdrs_dir"
    for i in "${!hdrs[@]}"; do
      hdrs[$i]=${hdrs[$i]#//:}
      header_name=$(basename "${hdrs[$i]}")
      cp "${hdrs[$i]}" "${hdrs_dir}/${header_name}"
      hdrs[$i]="${hdrs_base_path}/${header_name}"
    done
  fi

  echo -e "\nGenerating BUILD file content for support target: $dep"
  echo -e "\tName: $name"
  echo -e "\tHeaders count: ${#hdrs[@]}"

  pushd "../$archive_name"
  buildozer "new cc_import ${name}" //:__pkg__ >/dev/null 2>&1
  buildozer "set visibility \"//visibility:public\"" "${dep}" >/dev/null 2>&1
  buildozer "set static_library \"lib${name}.a\"" "${dep}" >/dev/null 2>&1
  if [ ${#hdrs[@]} -gt 0 ]; then
    buildozer "set hdrs glob([\"${hdrs_base_path}/*.h\"])" "${dep}" >/dev/null 2>&1
  fi
  popd
done

# Build each of the Swift library targets.
outputs=$(bazel cquery "set(${labels[@]})" --output=files "${build_flags[@]}")
bazel build "${labels[@]}" "${build_flags[@]}"
# Copy the build product files to the archive directory.
for output in $outputs; do
  if [[ $output == *.swiftinterface || $output == *.a || $output == *.swiftdoc ]]; then
    output_name=$(basename "$output")
    cp -R "$output" "../${archive_name}/${output_name}"
  fi
done

# Build the support targets.
outputs=$(bazel cquery "set(${c_deps[@]})" --output=files "${build_flags[@]}")
bazel build "${c_deps[@]}" "${build_flags[@]}"
# Copy the build product files to the archive directory.
for output in $outputs; do
  if [[ -f "$output" ]]; then
    output_name=$(basename "$output")
    cp -R "$output" "../${archive_name}/${output_name}"
  fi
done

popd
# -- end swift-syntax build --

# Package the outputs into a tarball.
tar -czf "${archive_name}.tar.gz" "$archive_name"

# Generate the expected sha256 checksum for the tarball.
openssl dgst -sha256 -binary "${archive_name}.tar.gz" | openssl base64 -A | sed 's/^/sha256-/' >"${archive_name}.tar.gz.sha256"
sha256_checksum=$(cat "${archive_name}.tar.gz.sha256")

echo "Dry-run completed successfully, SHA256 checksum for the archive is: $sha256_checksum"
