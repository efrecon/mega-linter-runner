#!/bin/sh

# Shell sanity. Stop on errors and undefined variables.
set -eu

# Level of verbosity, the higher the more verbose. All messages are sent to the
# stderr.
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

# Environment variables to pass to the container, possibly with values. One
# directive per **LINE**.
MLR_ENV=${MLR_ENV:-""}

# Docker client command to run
MLR_DOCKER=${MLR_DOCKER:-"docker"}

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
    sed -r 's/([a-zA-Z-])\)/-\1/'
  exit "${1:-0}"
}

while getopts "d:e:f:p:r:R:vh-" opt; do
  case "$opt" in
    d) # MegaLinter docker image to use (when empty: from -R, -f  and -r)
      MLR_IMAGE="$OPTARG";;
    e) # Environment variables to pass to the container, possibly with values. Can be repeated.
      # NOTE: Keep the formatting AS-IS. This is a multi-line variable.
      MLR_ENV="$OPTARG
${MLR_ENV}";;
    f) # MegaLinter flavor
      MLR_FLAVOR="$OPTARG";;
    p) # Directory containing the files to lint (default: current directory)
      MLR_PATH="$OPTARG";;
    r) # MegaLinter version
      MLR_RELEASE="$OPTARG";;
    R) # Docker registry to use, e.g. ghcr.io, docker.io
      MLR_REGISTRY="$OPTARG";;
    v) # Increase verbosity, will otherwise log on errors/warnings only
      MLR_VERBOSE=$((MLR_VERBOSE+1));;
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
trace() { if [ "${MLR_VERBOSE:-0}" -ge "3" ]; then _log "$1" TRC; fi; }
debug() { if [ "${MLR_VERBOSE:-0}" -ge "2" ]; then _log "$1" DBG; fi; }
verbose() { if [ "${MLR_VERBOSE:-0}" -ge "1" ]; then _log "$1" NFO; fi; }
warn() { _log "$1" WRN; }
error() { _log "$1" ERR && exit 1; }

# Download the url passed as the first argument to the destination path passed
# as a second argument. The destination will be the same as the basename of the
# URL, in the current directory, if omitted.
download() {
  if command -v curl >/dev/null; then
    curl -sSL -o "${2:-$(basename "$1")}" "$1"
    debug "Downloaded $1 to ${2:-$(basename "$1")} (curl)"
  elif command -v wget >/dev/null; then
    wget -q -O "${2:-$(basename "$1")}" "$1"
    debug "Downloaded $1 to ${2:-$(basename "$1")} (wget)"
  else
    error "Neither curl nor wget found, cannot download $1"
  fi
}

check_command() {
  trace "Checking $1 is an accessible command"
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Command not found: $1"
    return 1
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


# This is a readlink -f implementation so this script can (perhaps) run on MacOS
abspath() {
  is_abspath() {
    case "$1" in
      /* | ~*) true;;
      *) false;;
    esac
  }

  if [ -d "$1" ]; then
    ( cd -P -- "$1" && pwd -P )
  elif [ -L "$1" ]; then
    if is_abspath "$(readlink "$1")"; then
      abspath "$(readlink "$1")"
    else
      abspath "$(dirname "$1")/$(readlink "$1")"
    fi
  else
    printf %s\\n "$(abspath "$(dirname "$1")")/$(basename "$1")"
  fi
}

operating_system() {
  uname -o | tr '[:upper:]' '[:lower:]'
}

# Provided a path, return its absolute value so that it can be used as a host
# path inside the docker run command, e.g. volume mounts.
docker_abspath() {
  if [ "$(operating_system)" = "msys" ]; then
    # Enforce a double-slash at the front of the host path to the docker socket
    # to make docker desktop on windows happy when running from git bash.
    _path=$(abspath "$1")
    printf %s\\n "//${_path##/}"
  else
    abspath "$1"
  fi
}

# Return the size of the terminal in the same format as stty size, i.e. rows
# first, followed by columns. Uses the $COLUMNS and $LINES variables in
# priority, then tput (if found), then stty. Empty string when no guess is
# possible.
term_size() {
  if [ -n "${COLUMNS:-}" ] && [ -n "${LINES:-}" ]; then
    printf "%s  %s\n" "$LINES" "$COLUMNS"
  elif check_command tput; then
    _cols=$(tput cols 2>/dev/null || true)
    _lines=$(tput lines 2>/dev/null || true)
    if [ -n "$_cols" ] && [ -n "$_lines" ]; then
      printf "%s  %s\n" "$_lines" "$_cols"
    fi
  elif check_command stty; then
    stty size 2>/dev/null || true
  fi
}

if ! command -v "$MLR_DOCKER" >/dev/null 2>&1; then
    error "$MLR_DOCKER is not an executable command"
fi

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

# Start building the Docker command that we will run.
WDIR=$(abspath "$MLR_PATH")
set -- \
  --init \
  --rm \
  -v "$(docker_abspath "$MLR_SOCKET"):/var/run/docker.sock:rw" \
  -v "$(docker_abspath "$WDIR"):${WDIR}:rw" \
  -w "$(docker_abspath "$WDIR")" \
  "$MLR_IMAGE"
if [ -t 0 ]; then
  set -- -it "$@"
fi

# Enforce environment variables passed through the command line. If
# DEFAULT_WORKSPACE is not one of them, we will set it to the current working
# directory. Also, pass further COLUMNS and LINES if they are provided, or add
# them if they can be guessed. This is to ensure that some linters (PowerShell)
# behave properly.
_workspace=0
_columns=0
_lines=0
while IFS= read -r varspec || [ -n "$varspec" ]; do
  if [ -n "$varspec" ]; then
    _pass_spec=1
    if printf %s\\n "$varspec" | grep -q '^DEFAULT_WORKSPACE='; then
      _workspace=1
    fi
    if printf %s\\n "$varspec" | grep -q '^COLUMNS'; then
      if printf %s\\n "$varspec" | grep -qE '^COLUMNS=[0-9]+'; then
        _columns=1
      elif [ -n "${COLUMNS:-}" ]; then
        _columns=1
        varspec="COLUMNS=${COLUMNS}"
      else
        _pass_spec=0
      fi
    fi
    if printf %s\\n "$varspec" | grep -q '^LINES'; then
      if printf %s\\n "$varspec" | grep -qE '^LINES=[0-9]+'; then
        _lines=1
      elif [ -n "${LINES:-}" ]; then
        _lines=1
        varspec="LINES=${LINES}"
      else
        _pass_spec=0
      fi
    fi
    if [ "$_pass_spec" = 1 ]; then
      debug "Passing $varspec to container"
      set -- -e "$varspec" "$@"
    fi
  fi
done <<EOF
$(printf %s\\n "$MLR_ENV")
EOF

term_size=$(term_size)
if [ -n "$term_size" ]; then
  if [ "$_columns" = "0" ]; then
    debug "Passing COLUMNS=${term_size#* } to container"
    set -- -e "COLUMNS=${term_size#* }" "$@"
  fi
  if [ "$_lines" = "0" ]; then
    debug "Passing LINES=${term_size% *} to container"
    set -- -e "LINES=${term_size% *}" "$@"
  fi
else
  warn "Cannot guess terminal size, COLUMNS and LINES will not be passed to the container"
fi
if [ "$_workspace" = "0" ]; then
  debug "Exporting DEFAULT_WORKSPACE=${WDIR}"
  DEFAULT_WORKSPACE=$(docker_abspath "$WDIR")
  export DEFAULT_WORKSPACE
fi

# Pass all environment variables matching relevant patterns/names. These are the
# common variables recognised by the MegaLinter, followed by the descriptor keys
# of the language linters, the formats linters and the tooling formats linters.
while IFS= read -r var; do
  # Exact matches on variable names
  for v in \
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
    GITHUB_ACTIONS \
    GITHUB_EVENT_NAME \
    GITHUB_TOKEN \
    GITHUB_WORKSPACE \
    GITHUB_OUTPUT \
    GITHUB_REPOSITORY \
    GITHUB_REF \
    GITHUB_RUN_ID \
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
    GITLAB_CI \
    CI_PIPELINE_SOURCE \
    CI_MERGE_REQUEST_EVENT_TYPE \
    CI_PROJECT_DIR \
    TF_BUILD \
    BUILD_REASON
  do
    if [ "$v" = "$var" ]; then
      verbose "Passing $var to container"
      set -- -e "$var" "$@"
    fi
  done

  # Match the beginning of the variable name
  for ptn in \
    "BASH_" \
    "C_" \
    "CLOJURE_" \
    "COFFEE_" \
    "CPP_" \
    "CSHARP_" \
    "DART_" \
    "GO_" \
    "GROOVY_" \
    "JAVA_CHECKSTYLE_" \
    "JAVA_PMD_" \
    "JAVASCRIPT_" \
    "JSX_" \
    "KOTLIN_" \
    "LUA_" \
    "MAKEFILE_" \
    "PERL_" \
    "PHP_" \
    "POWERSHELL_POWERSHELL_" \
    "PYTHON_" \
    "R_" \
    "RAKU_" \
    "RUBY_" \
    "RUST_" \
    "SALESFORCE_" \
    "SCALA_" \
    "SQL_" \
    "SWIFT_SWIFTLINT_" \
    "TSX_" \
    "TYPESCRIPT_" \
    "VBDOTNET_" \
    "CSS_" \
    "ENV_" \
    "GRAPHQL_" \
    "HTML_" \
    "JSON_" \
    "LATEX_" \
    "MARKDOWN_" \
    "PROTOBUF_" \
    "RST_" \
    "XML_" \
    "YAML_" \
    "ACTION_" \
    "ARM_" \
    "BICEP_" \
    "CLOUDFORMATION_" \
    "DOCKERFILE_" \
    "EDITORCONFIG_" \
    "GHERKIN_" \
    "KUBERNETES_" \
    "OPENAPI_" \
    "PUPPET_" \
    "SNAKEMAKE_" \
    "TEKTON_" \
    "TERRAFORM_"
  do
    # When the pattern can be removed from the name of the variable name, the
    # result is different than the variable name. Then the variable name matches
    # the pattern.
    if [ "${var#"$ptn"}" != "$var" ]; then
      verbose "Passing $var to container"
      set -- -e "$var" "$@"
    fi
  done
done <<EOF
$(env | grep -Eo '^[^=]+')
EOF

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  debug "Mounting GITHUB_OUTPUT file into container"
  set -- -v "$(docker_abspath "$GITHUB_OUTPUT"):${GITHUB_OUTPUT}:rw" "$@"
fi

trace "Running: $MLR_DOCKER run $*"
exec "$MLR_DOCKER" run "$@"
