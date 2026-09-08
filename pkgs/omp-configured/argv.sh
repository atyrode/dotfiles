# shellcheck shell=bash
# Linux/Darwin launch grammar, audited against the pinned upstream flag-tables.ts
# and cli-commands.ts. checks/omp/omp-wrapper.nix checks live completion metadata.
# Extensions retain their own parsing; unknown long flags may consume a non-flag
# successor during upstream command dispatch, but not a flag-shaped successor.
omp_required_flags=(
  --add-dir --alias --api-key --append-system-prompt --approval-mode --config
  --cwd --export --extension -e --fork --hook --max-time --mode --model --models
  --plan --plan-yolo-into --plugin-dir --prewalk-into --profile --prompt-cache-key
  --provider --provider-session-id --service-tier --session-dir --skills --slow
  --smol --system-prompt --thinking --tools --trusted-extension
)
omp_optional_flags=(--resume -r --session)
omp_boolean_flags=(
  --advisor --allow-home --auto-approve --continue -c --external-thinking
  --from-claude --from-codex --help -h --hide-thinking --no-extensions --no-lsp
  --no-prewalk --no-pty --no-rules --no-session --no-skills --no-title --no-tools
  --plan-yolo --prewalk --print -p --print-thoughts --version -v --yolo
)
omp_subcommands=(
  __complete acp agents auth-broker auth-gateway bench browser-relay cleanse
  commit completions compress config dry-balance gallery gc git grep grievances
  images img if-bench install join launch models plugin ps q read render say
  search setup share shell ssh stats tiny-models token ttsr update usage worktree wt
)

omp_contains() {
  local needle="$1" candidate
  shift
  for candidate in "$@"; do
    [[ "$candidate" != "$needle" ]] || return 0
  done
  return 1
}
takes_required_value() { omp_contains "$1" "${omp_required_flags[@]}"; }
takes_optional_value() { omp_contains "$1" "${omp_optional_flags[@]}"; }
is_known_boolean() { omp_contains "$1" "${omp_boolean_flags[@]}"; }
is_known_subcommand() { omp_contains "$1" "${omp_subcommands[@]}"; }

omp_consumes_value() {
  [[ "$1" != --*=* && $# -gt 1 ]] || return 1
  takes_required_value "$1" && return 0
  if takes_optional_value "$1"; then
    [[ -n "$2" && "$2" != -* ]]
  else
    [[ "$1" == --* && "$2" != -* ]] && ! is_known_boolean "$1"
  fi
}

# Profile/alias extraction precedes ordinary launch parsing. Its shadowable
# --plan option consumes only non-flag values, unlike the launch parser.
refuse_bootstrap_state_flags() {
  local -a argv=("$@")
  local i arg
  for ((i = 0; i < ${#argv[@]}; i++)); do
    arg="${argv[$i]}"
    [[ "$arg" != -- ]] || return 0
    if ((i == 0)) && is_known_subcommand "$arg" &&
      [[ "$arg" != launch && "$arg" != acp ]]; then
      return 0
    fi
    case "$arg" in
      --profile | --profile=* | --alias | --alias=*)
        refuse_flag "${arg%%=*}"
        ;;
      --plan)
        if ((i + 1 < ${#argv[@]})) && [[ "${argv[$((i + 1))]}" != -* ]]; then
          i=$((i + 1))
        fi
        ;;
      *)
        if ((i + 1 < ${#argv[@]})) && omp_consumes_value "$arg" "${argv[$((i + 1))]}"; then
          i=$((i + 1))
        fi
        ;;
    esac
  done
}

# The sourcing launcher consumes the two classification outputs.
# shellcheck disable=SC2034
classify_invocation() {
  subcommand=""
  subcommand_index=-1
  local -a argv=("$@")
  local i arg
  for ((i = 0; i < ${#argv[@]}; i++)); do
    arg="${argv[$i]}"
    [[ "$arg" != -- ]] || return 0
    if ((i == 0)); then
      case "$arg" in
        --help | -h | --version | -v | help)
          subcommand=__passthrough__
          return 0
          ;;
      esac
    fi
    if [[ "$arg" != -* ]]; then
      if is_known_subcommand "$arg"; then
        subcommand="$arg"
        subcommand_index="$i"
      fi
      return 0
    fi
    if ((i + 1 < ${#argv[@]})) && omp_consumes_value "$arg" "${argv[$((i + 1))]}"; then
      i=$((i + 1))
    fi
  done
}
