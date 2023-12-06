#!/bin/sh

# This script outputs foldable HTML/markdown code to represent the git diff of
# the files passed as parameters or (when no arg given) from all modified files
# seen by git.

# Shell sanity. Stop on errors and undefined variables.
set -eu

# Verbosity
MLR_VERBOSE=${MLR_VERBOSE:-0}

# Megalinter version to run
MLR_RELEASE=${MLR_RELEASE:-"latest"}

# Flavor of the megalinter to run
MLR_FLAVOR=${MLR_FLAVOR:-"all"}

# Directory containing the files to lint (default: current directory)
MLR_PATH=${MLR_PATH:-"$(pwd)"}

# Registry
MLR_REGISTRY=${MLR_REGISTRY:-"ghcr.io"}

# Docker image to use, empty to let other variables decide.
MLR_IMAGE=${MLR_IMAGE:-""}

# Location of the local docker socket to map into the container.
MLR_SOCKET=${MLR_SOCKET:-"/var/run/docker.sock"}

# GitHub URL
MLR_GITHUB=${MLR_GITHUB:-"https://github.com"}

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 Run the MegaLinter as a Docker container" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z-])\)/-\1/'
  exit "${1:-0}"
}

while getopts "d:f:p:r:R:vh-" opt; do
  case "$opt" in
    d) # MegaLinter docker image to use (when empty: from -R, -f  and -r)
      MLR_IMAGE="$OPTARG";;
    f) # MegaLinter flavor
      MLR_FLAVOR="$OPTARG";;
    p) # Directory containing the files to lint (default: current directory)
      MLR_PATH="$OPTARG";;
    r) # MegaLinter version
      MLR_RELEASE="$OPTARG";;
    R) # Docker registry to use, e.g. ghcr.io, docker.io
      MLR_REGISTRY="$OPTARG";;
    v) # Turn on verbosity, will otherwise log on errors/warnings only
      MLR_VERBOSE=1;;
    h) # Print help and exit
      usage;;
    -) # End of options, everything after are path to files to process
      break;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# PML: Poor Man's Logging
_log() {
  printf '[%s] [%s] [%s] %s\n' \
    "$(basename "$0")" \
    "${2:-LOG}" \
    "$(date +'%Y%m%d-%H%M%S')" \
    "${1:-}" \
    >&2
}
# shellcheck disable=SC2015 # We are fine, this is just to never fail
verbose() { [ "$MLR_VERBOSE" = "1" ] && _log "$1" NFO || true ; }
warn() { _log "$1" WRN; }
error() { _log "$1" ERR && exit 1; }

# Download the url passed as the first argument to the destination path passed
# as a second argument. The destination will be the same as the basename of the
# URL, in the current directory, if omitted.
download() {
  if command -v curl >/dev/null; then
    curl -sSL -o "${2:-$(basename "$1")}" "$1"
  elif command -v wget >/dev/null; then
    wget -q -O "${2:-$(basename "$1")}" "$1"
  else
    error "Neither curl nor wget found, cannot download $1"
  fi
}


# Guess version of GH project passed as a parameter using the tags in the HTML
# description.
gh_version() {
  verbose "Guessing latest stable version for project $1"
  # This works on the HTML from GitHub as follows:
  # 1. Start from the list of tags, they point to the corresponding release.
  # 2. Extract references to the release page, force a possible v and a number
  #    at start of sub-path
  # 3. Use slash and quote as separators and extract the tag/release number with
  #    awk. This is a bit brittle.
  # 4. Remove leading v, if there is one (there will be in most cases!)
  # 5. Extract only pure SemVer sharp versions
  # 6. Just keep the top one, i.e. the latest release.
  download "${MLR_GITHUB%/}/${1}/tags" -|
    grep -Eo "<a href=\"/${1}/releases/tag/v?[0-9][^\"]*" |
    awk -F'[/\"]' '{print $7}' |
    sed 's/^v//g' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
    sort -n -r |
    head -1
}


# Performs glob matching, little like Tcl. No support for |.
# $1 is the matching pattern
# $2 is the string to test against
glob() {
  # Disable globbing.
  # This ensures that the case is not globbed.
  _oldstate=$(set +o); set -f
  # shellcheck disable=2254
  case "$2" in
    $1) set +vx; eval "$_oldstate"; return 0;;
  esac
  set +vx; eval "$_oldstate"
  return 1
}

# When no image is given, build it from the registry, flavor and release.
if [ -z "$MLR_IMAGE" ]; then
  # Empty flavor means all linters, so we use the all flavor.
  [ -z "$MLR_FLAVOR" ] && MLR_FLAVOR="all"
  # Dynamically resolve "latest" to the latest version of the megalinter.
  [ -z "$MLR_RELEASE" ] && MLR_RELEASE="latest"
  [ "$MLR_RELEASE" = "latest" ] && MLR_RELEASE=$(gh_version "oxsecurity/megalinter")
  # Construct the image name from the registry, flavor and release.
  if [ "$MLR_FLAVOR" = "all" ]; then
    MLR_IMAGE="${MLR_REGISTRY}/oxsecurity/megalinter:v${MLR_RELEASE#v}"
  else
    MLR_IMAGE="${MLR_REGISTRY}/oxsecurity/megalinter-${MLR_FLAVOR}:v${MLR_RELEASE#v}"
  fi
else
  [ -n "$MLR_FLAVOR" ] && warn "Ignoring flavor $MLR_FLAVOR as image $MLR_IMAGE is given"
  [ -n "$MLR_RELEASE" ] && warn "Ignoring release $MLR_RELEASE as image $MLR_IMAGE is given"
fi

# When files are explicitly given, use them. Append them to the existing
# MEGLINTER_FILES_TO_LINT list
if [ "$#" -gt 0 ]; then
  # Build/append to the list of files to lint. Use comma as separator.
  _oifs="$IFS"; IFS=','
  if [ -z "${MEGALINTER_FILES_TO_LINT:-}" ]; then
    MEGALINTER_FILES_TO_LINT="$*"
  else
    MEGALINTER_FILES_TO_LINT="${MEGALINTER_FILES_TO_LINT},$*"
  fi
  IFS="$_oifs"
  export MEGALINTER_FILES_TO_LINT
  verbose "Running MegaLinter ${MLR_RELEASE} (${MLR_FLAVOR}) on ${MEGALINTER_FILES_TO_LINT}"
else
  verbose "Running MegaLinter ${MLR_RELEASE} (${MLR_FLAVOR}) on ${MLR_PATH}"
fi

# Start building the Docker command that we will run
set -- \
  --rm \
  -v "${MLR_SOCKET}:/var/run/docker.sock:rw" \
  -v "${MLR_PATH}:/tmp/lint:rw" \
  "$MLR_IMAGE"

# Pass all environment variables that start with one of the following patterns.
# The patterns are the common variables recognised by the MegaLinter, followes
# by the descriptor keys of the language linters, the formats linters and the
# tooling formats linters.
while IFS= read -r var; do
  for ptn in \
    ADDITIONAL_EXCLUDED_DIRECTORIES \
    APPLY_FIXES \
    CLEAR_REPORT_FOLDER \
    DEFAULT_BRANCH \
    DEFAULT_WORKSPACE \
    DISABLE_ERRORS \
    DISABLE \
    DISABLE_LINTERS \
    DISABLE_ERRORS_LINTERS \
    ENABLE \
    ENABLE_LINTERS \
    EXCLUDED_DIRECTORIES \
    EXTENDS \
    FAIL_IF_MISSING_LINTER_IN_FLAVOR \
    FAIL_IF_UPDATED_SOURCES \
    FILTER_REGEX_EXCLUDE \
    FILTER_REGEX_INCLUDE \
    FLAVOR_SUGGESTIONS \
    FORMATTERS_DISABLE_ERRORS \
    GIT_AUTHORIZATION_BEARER \
    GITHUB_TOKEN \
    GITHUB_WORKSPACE \
    GITHUB_OUTPUT \
    IGNORE_GENERATED_FILES \
    IGNORE_GITIGNORED_FILES \
    JAVASCRIPT_DEFAULT_STYLE \
    LINTER_RULES_PATH \
    LOG_FILE \
    LOG_LEVEL \
    MARKDOWN_DEFAULT_STYLE \
    MEGALINTER_CONFIG \
    MEGALINTER_FILES_TO_LINT \
    PARALLEL \
    PLUGINS \
    POST_COMMANDS \
    PRE_COMMANDS \
    PRINT_ALPACA \
    PRINT_ALL_FILES \
    REPORT_OUTPUT_FOLDER \
    SECURED_ENV_VARIABLES \
    SECURED_ENV_VARIABLES_DEFAULT \
    SHOW_ELAPSED_TIME \
    SHOW_SKIPPED_LINTERS \
    SKIP_CLI_LINT_MODES \
    TYPESCRIPT_DEFAULT_STYLE \
    VALIDATE_ALL_CODEBASE \
    "BASH_*" \
    "C_*" \
    "CLOJURE_*" \
    "COFFEE_*" \
    "CPP_*" \
    "CSHARP_*" \
    "DART_*" \
    "GO_*" \
    "GROOVY_*" \
    "JAVA_CHECKSTYLE_*" \
    "JAVA_PMD_*" \
    "JAVASCRIPT_*" \
    "JSX_*" \
    "KOTLIN_*" \
    "LUA_*" \
    "MAKEFILE_*" \
    "PERL_*" \
    "PHP_*" \
    "POWERSHELL_POWERSHELL_*" \
    "PYTHON_*" \
    "R_*" \
    "RAKU_*" \
    "RUBY_*" \
    "RUST_*" \
    "SALESFORCE_*" \
    "SCALA_*" \
    "SQL_*" \
    "SWIFT_SWIFTLINT_*" \
    "TSX_*" \
    "TYPESCRIPT_*" \
    "VBDOTNET_*" \
    "CSS_*" \
    "ENV_*" \
    "GRAPHQL_*" \
    "HTML_*" \
    "JSON_*" \
    "LATEX_*" \
    "MARKDOWN_*" \
    "PROTOBUF_*" \
    "RST_*" \
    "XML_*" \
    "YAML_*" \
    "ACTION_*" \
    "ARM_*" \
    "BICEP_*" \
    "CLOUDFORMATION_*" \
    "DOCKERFILE_*" \
    "EDITORCONFIG_*" \
    "GHERKIN_*" \
    "KUBERNETES_*" \
    "OPENAPI_*" \
    "PUPPET_*" \
    "SNAKEMAKE_*" \
    "TEKTON_*" \
    "TERRAFORM_*" ; do
    if glob "$ptn" "$var"; then
      verbose "Passing $var to container"
      set -- -e "$var" "$@"
    fi
  done
done <<EOF
$(env | grep -Eo '^[^=]+')
EOF

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  verbose "Mounting GITHUB_OUTPUT file into container"
  set -- -v "${GITHUB_OUTPUT}:${GITHUB_OUTPUT}:rw" "$@"
fi

verbose "Running: docker run $*"
exec docker run "$@"
