# swift-syntax-prebuilt

This repository is designed to provide pre-built Bazel compatible targets for the [apple/swift-syntax](https://github.com/apple/swift-syntax) repository.

## Supported platforms

Each release ships a single tarball with binary artifacts for multiple platforms; the embedded `BUILD.bazel` selects the right artifacts for the consumer's target via `@platforms//os` + `@platforms//cpu` constraints, so a single `archive_override` works for every supported platform:

- macOS arm64
- Linux x86_64

## Usage

Update your `MODULE.bazel` file to override the `swift-syntax` repository with this one.

See the [releases page](https://github.com/square/swift-syntax-prebuilt/releases) for available versions.

```starlark
bazel_dep(
    name = "swift-syntax",
    version = "x.x.x",
)

archive_override(
    module_name = "swift-syntax",
    urls = ["https://github.com/square/swift-syntax-prebuilt/releases/download/x.x.x/swift-syntax-x.x.x.tar.gz"],
)
```

## Adding `swift-syntax` versions

- File an issue if the version you want is not available.
- Maintainer will run the [build-publish](https://github.com/square/swift-syntax-prebuilt/actions/workflows/build-publish.yml) action.

## Build script (`build.sh`)

`build.sh` runs in two phases so the work can be split across heterogeneous CI runners (macOS for `darwin-*` targets, Linux for `linux-*` targets):

```bash
# Phase 1: build for one platform. Run once per supported TARGET_PLATFORM
# (macos-arm64, linux-x86_64, linux-arm64). Outputs ./staging/<platform>.tar.gz.
SWIFT_SYNTAX_VERSION=602.0.0 \
RULES_SWIFT_VERSION=3.1.2 \
TARGET_PLATFORM=macos-arm64 \
  ./build.sh build

# Phase 2: combine all per-platform staging tarballs into the final release
# archive. Generates a BUILD.bazel that uses select() over (os, cpu) plus a
# top-level MODULE.bazel.
SWIFT_SYNTAX_VERSION=602.0.0 \
RULES_SWIFT_VERSION=3.1.2 \
  ./build.sh package
```

The GitHub Actions workflows (`dry-run.yml`, `build-publish.yml`) wire these phases into a fan-out / fan-in pipeline: one build job per platform, then a single packaging job that downloads each platform's staging artifact and produces the released tarball.
