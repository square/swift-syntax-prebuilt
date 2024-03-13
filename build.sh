#!/bin/bash

set -euo pipefail

# This script builds the SwiftSyntax prebuilt binaries and outputs the SHA256 checksum for the archive.
# NOTE: this script expects that the swift-syntax repository is checked out in the same directory as this script.
#
# Required environment variables:
#   - SWIFT_SYNTAX_VERSION: The version of SwiftSyntax to build.
#   - RULES_SWIFT_VERSION: The version of rules_swift to use for the archive MODULE.bazel file.
#   - MACOS_VERSION: The minimum macOS version to target.
#
# Optional environment variables:
#   - BUILD_NUMBER: The build number to append to the release tag.
#   - SWIFT_SYNTAX_RULES_SWIFT_VERSION: The version of rules_swift to use for building within the swift-syntax repository

release_tag="$SWIFT_SYNTAX_VERSION"
if [ -n "${BUILD_NUMBER:-}" ]; then
  release_tag="$release_tag+$BUILD_NUMBER"
fi

archive_name="swift-syntax-$release_tag"
archs=("x86_64" "arm64")

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
    repo_name = "build_bazel_rules_swift",
)
EOF

# Create the BUILD file which will be used to include the exposed targets.
cat >"$archive_name/BUILD.bazel" <<EOF
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_import")

config_setting(
    name = "darwin_x86_64",
    constraint_values = [
        "@platforms//os:macos",
        "@platforms//cpu:x86_64",
    ],
)

config_setting(
    name = "darwin_arm64",
    constraint_values = [
        "@platforms//os:macos",
        "@platforms//cpu:aarch64",
    ],
)

EOF

# -- start swift-syntax build --
pushd swift-syntax

# TODO: for swift-syntax 508-509 there is a missing dep on `SwiftOperators` which causes build to fail.
# Use buildozer to add the missing dep.
buildozer "add deps :SwiftOperators" //:SwiftSyntaxMacros

# Override the rules_swift version if it is set.
if [ -n "${SWIFT_SYNTAX_RULES_SWIFT_VERSION:-}" ]; then
  cat >>"MODULE.bazel" <<EOF
git_override(
    module_name = "rules_swift",
    commit = "$SWIFT_SYNTAX_RULES_SWIFT_VERSION",
    remote = "https://github.com/bazelbuild/rules_swift.git",
)

EOF
fi

# Shared build flags:
#  - set the minimum macOS version to the version specified in the workflow input
#  - set the host macOS version to the version specified in the workflow input
#  - enable library evolution
build_flags=(
  --macos_minimum_os="$MACOS_VERSION"
  --host_macos_minimum_os="$MACOS_VERSION"
  --features="swift.enable_library_evolution"
  --features="swift.emit_private_swiftinterface"
)

# Collect the labels for the targets that will be exported.
# Targets exported are those suffixed with `_opt`.
# The cquery output looks like: `//:SwiftBasicFormat_opt (5d78ae7)` and we take just the label.
labels=($(bazel cquery "filter(_opt, //...)" "${build_flags[@]}" | sed 's/ (.*//'))

# Create the BUILD file for each of the swift-syntax targets.
for label in ${labels[@]}; do
  # Collect information about the target, we need deps to be propagated to downstream targets.
  non_opt_label=$(echo $label | sed 's/_opt$//')
  module_name=$(buildozer "print name" $non_opt_label)
  dependencies=$(buildozer "print deps" $non_opt_label | sed 's/^\[//' | sed 's/\]$//')

  # Create the `swift_import` target for this module.
  # Do this in the directory to make it easier to use buildozer with labels.
  pushd "../$archive_name"
  buildozer "new swift_import ${module_name}_opt" //:__pkg__
  buildozer "set module_name \"${module_name}\"" //:${module_name}_opt
  buildozer "set visibility \"//visibility:public\"" //:${module_name}_opt
  buildozer "set_select archives :darwin_x86_64 \"x86_64/lib${module_name}.a\" :darwin_arm64 \"arm64/lib${module_name}.a\"" //:${module_name}_opt
  buildozer "set_select swiftdoc :darwin_x86_64 \"x86_64/${module_name}.swiftdoc\" :darwin_arm64 \"arm64/${module_name}.swiftdoc\"" //:${module_name}_opt
  buildozer "set_select swiftinterface :darwin_x86_64 \"x86_64/${module_name}.private.swiftinterface\" :darwin_arm64 \"arm64/${module_name}.private.swiftinterface\"" //:${module_name}_opt
  if [ -n "$dependencies" ]; then
    # Add '_opt' to each word in the dependencies list and set the deps.
    dependencies=($(echo $dependencies | sed 's/ /_opt /g')_opt)
    buildozer "set deps ${dependencies[*]}" //:${module_name}_opt
  fi
  popd
done

# Build the module for each architecture we suppport.
for arch in ${archs[@]}; do
  arch_flags=("--cpu=darwin_${arch}")
  outputs=$(bazel cquery "set(${labels[@]})" --output=files "${build_flags[@]}" "${arch_flags[@]}")
  bazel build "${labels[@]}" "${build_flags[@]}" "${arch_flags[@]}"

  # Copy the .private.swiftinterface, .a, .swiftdoc file to the archive directory within a subdirectory for the architecture.
  for output in $outputs; do
    if [[ $output == *.private.swiftinterface || $output == *.a || $output == *.swiftdoc ]]; then
      output_name=$(basename "$output")
      archive_dir_path="../${archive_name}/${arch}"
      mkdir -p "$archive_dir_path"
      archive_path="$archive_dir_path/${output_name}"
      cp -R "$output" "$archive_path"
    fi
  done
done

popd
# -- end swift-syntax build --

# Package the outputs into a tarball.
tar -czf "${archive_name}.tar.gz" "$archive_name"

# Generate the expected sha256 checksum for the tarball.
bzlmod_sha256=$(openssl dgst -sha256 -binary "${archive_name}.tar.gz" | openssl base64 -A | sed 's/^/sha256-/')

# Output the sha256 checksum so scripts can use it.
echo "$bzlmod_sha256"
