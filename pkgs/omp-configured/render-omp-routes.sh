#!/usr/bin/env bash
# Renders the managed OMP routing — every preset launcher's role → model map
# with fallback chains — as a terminal help page. Runs at package build time,
# so the page is regenerated from the YAML sources on every apply and cannot
# drift from the deployed configuration.
set -euo pipefail

[[ $# -ge 4 ]] || {
  echo 'usage: render-omp-routes.sh <version> <agents-dir> <defaults.yml> <name|description|preset.yml>...' >&2
  exit 2
}

version=$1
agents_dir=$2
defaults=$3
shift 3

# Provider is encoded as a colorblind-safe blue/orange pair, and agent-backed
# roles carry a shape marker so no information rides on color alone.
if [[ ${OMP_ROUTES_COLOR:-1} == 1 ]]; then
  bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'
  openai=$'\e[38;5;33m' anthropic=$'\e[38;5;208m' other=$'\e[38;5;133m'
else
  bold='' dim='' reset='' openai='' anthropic='' other=''
fi

mapfile -t agents < <(
  find "$agents_dir" -maxdepth 1 -name '*.md' -printf '%f\n' | sed 's/\.md$//' | sort
)

is_agent() {
  local candidate
  for candidate in "${agents[@]}"; do
    [[ $candidate == "$1" ]] && return 0
  done
  return 1
}

short_model() {
  local model=$1
  model=${model#openai-codex/}
  printf '%s' "${model#anthropic/}"
}

model_color() {
  case $1 in
    openai-codex/*) printf '%s' "$openai" ;;
    anthropic/*) printf '%s' "$anthropic" ;;
    *) printf '%s' "$other" ;;
  esac
}

paint_model() {
  printf '%s%s%s' "$(model_color "$1")" "$(short_model "$1")" "$reset"
}

pad_model() {
  local model=$1 width=$2
  printf '%s%-*s%s' "$(model_color "$model")" "$width" "$(short_model "$model")" "$reset"
}

merge_configs() {
  local json='{}' file
  for file in "$@"; do
    json=$(printf '%s\n%s\n' "$json" "$(yq eval -o=json -I=0 '.' "$file")" | jq -cs '.[0] * .[1]')
  done
  printf '%s' "$json"
}

role_order=(default task plan slow designer reviewer librarian sonic advisor smol tiny commit)

render_profile() {
  local name=$1 description=$2 merged=$3
  local thinking advisor_enabled fallback
  thinking=$(jq -r '.defaultThinkingLevel // "medium"' <<<"$merged")
  advisor_enabled=$(jq -r '.advisor.enabled // false' <<<"$merged")
  fallback=$(jq -r '(.retry.enabled // false) and (.retry.modelFallback // false)' <<<"$merged")

  local advisor_note='advisor off' fallback_note='fallback disabled'
  [[ $advisor_enabled == true ]] && advisor_note='advisor on'
  [[ $fallback == true ]] && fallback_note='fallback enabled'

  printf '%s%s%s  %s\n' "$bold" "$name" "$reset" "$description"
  printf '  %sthinking %s · %s · %s%s\n' "$dim" "$thinking" "$fallback_note" "$advisor_note" "$reset"

  local -a roles=()
  local role
  for role in "${role_order[@]}"; do
    if jq -e --arg role "$role" '.modelRoles[$role] != null' <<<"$merged" >/dev/null; then
      roles+=("$role")
    fi
  done
  while IFS= read -r role; do
    [[ " ${role_order[*]} " == *" $role "* ]] || roles+=("$role")
  done < <(jq -r '.modelRoles | keys[]' <<<"$merged" | sort)

  local primary override marker line step
  local -a chain
  for role in "${roles[@]}"; do
    # A disabled advisor never runs; don't list it as a route.
    [[ $role == advisor && $advisor_enabled != true ]] && continue
    primary=$(jq -r --arg role "$role" '.modelRoles[$role]' <<<"$merged")
    marker=' '
    if is_agent "$role"; then
      marker='●'
    fi
    line=$(printf '  %s %-10s %s' "$marker" "$role" "$(pad_model "$primary" 24)")
    if [[ $fallback == true ]]; then
      mapfile -t chain < <(
        jq -r --arg role "$role" '.retry.fallbackChains[$role] // [] | .[]' <<<"$merged"
      )
      for step in "${chain[@]}"; do
        line+=$(printf ' %s→%s %s' "$dim" "$reset" "$(paint_model "$step")")
      done
    fi
    override=$(jq -r --arg role "$role" '.task.agentModelOverrides[$role] // ""' <<<"$merged")
    if [[ -n $override && $override != "$primary" ]]; then
      line+=$(printf ' %s(task override: %s)%s' "$dim" "$(short_model "$override")" "$reset")
    fi
    printf '%s\n' "$line"
  done
  printf '\n'
}

printf '%sOMP managed routing%s — oh-my-pi %s\n' "$bold" "$reset" "$version"
printf '%sbundled agents: %s — ● marks a role backed by a bundled agent%s\n\n' \
  "$dim" "${agents[*]}" "$reset"

for spec in "$@"; do
  IFS='|' read -r name description preset <<<"$spec"
  render_profile "$name" "$description" "$(merge_configs "$defaults" "$preset")"
done

printf '%s' "$dim"
printf 'scout is deliberately unpinned: it rides the smol route via its upstream frontmatter.\n'
printf 'omp runs your own mutable config, unmanaged, so it is not listed above.\n'
printf 'ompu adds isolated state and restricted tools over the defaults routing shown.\n'
printf "pick a launcher interactively with 'code'; design rationale in omp/PROFILES.md.\n"
printf 'source: omp/defaults.yml + omp/presets/*.yml — edit in the dotfiles repo, then zconf.\n'
printf '%s' "$reset"
