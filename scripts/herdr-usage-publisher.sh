#!/usr/bin/env bash
set -uo pipefail

readonly interval_seconds=300
readonly ttl_ms=720000
readonly source_id="atyrode:usage"
# Herdr v0.7.4 sidebar geometry: non-first rows sit behind a 3-cell prefix
# (5 when indented) and the workspace scrollbar can take one more column, so
# the managed config widens the sidebar to 28 to guarantee 21 usable cells.
# The glyph-fused positional grammar's worst case (`C100 100/100 X100 100`)
# is exactly 21; the slice below is a safety net only.
readonly max_line_chars=21

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
manifest="${CODE_AUTH_VAULTS_FILE:-$config_home/code/auth-vaults.json}"
selection_state="${CODE_AUTH_STATE:-$state_home/atyrode/code-auth-vault-state.json}"
herdr_sessions="$config_home/herdr/sessions"

declare -A usage_by_id=()
declare -A usage_by_broker=()

usage_line() {
  local broker_url=$1 token_file=$2 token response
  [[ -r "$token_file" ]] || return 1
  token="$(<"$token_file")"
  [[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || return 1

  response="$(
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl --config - -sf --max-time 15 --url "${broker_url%/}/v1/usage"
  )" || return 1

  jq -er --argjson max_line_chars "$max_line_chars" '
		def used_fraction:
			if (.amount.usedFraction | type) == "number" then .amount.usedFraction
			elif (.amount.used | type) == "number" and
				(.amount.limit | type) == "number" and .amount.limit > 0
			then .amount.used / .amount.limit
			else empty
			end;
		def bucket:
			((.window.id // "") | ascii_downcase) as $id
			| ((.window.label // .label // "") | ascii_downcase) as $label
			| (.window.durationMs // 0) as $duration
			| if $id == "5h" or $duration == 18000000 or ($label | test("5[ -]?hour"))
			  then "5h"
			  elif $id == "7d" or $duration == 604800000 or ($label | test("7[ -]?day"))
			  then "7d"
			  else empty
			  end;
		def variant:
			((.scope.tier // "") | ascii_downcase) as $tier
			| ((.label // "") | ascii_downcase) as $label
			| if ($tier | contains("fable")) or ($label | contains("fable")) then "fable"
			  elif ($tier | contains("spark")) or ($label | contains("spark")) then "spark"
			  else "core"
			  end;
		def chosen($rows; $provider; $bucket; $variant):
			[
				$rows[]
				| select(
					.provider == $provider and .bucket == $bucket and .variant == $variant
				)
			]
			| if length == 0 then null else (sort_by(.rank, .used) | last.used) end;
		def pct:
			([., 0] | max | [., 1] | min) * 100 + 0.5 | floor;
		def num($v):
			if $v != null then "\($v | pct)" else "-" end;
		def provider_line($glyph; $five; $seven; $fable):
			if $five == null and $seven == null and $fable == null then empty
			else
				$glyph + num($five) + " " + num($seven)
				+ (if $fable != null then "/\($fable | pct)" else "" end)
			end;
		(if type == "array" then . else (.reports // []) end)
		| [
			.[]?
			| select(.provider == "anthropic" or .provider == "openai-codex")
			| .provider as $provider
			| .limits[]?
			| (used_fraction) as $used
			| select(($used | type) == "number")
			| {
				provider: $provider,
				bucket: bucket,
				variant: variant,
				used: $used,
				rank: (if .scope.tier == "-" then 2 else 1 end)
			  }
		] as $rows
		| (chosen($rows; "anthropic"; "5h"; "core")) as $cl5
		| (chosen($rows; "anthropic"; "7d"; "core")) as $cl7
		| (chosen($rows; "anthropic"; "7d"; "fable")) as $fable
		| (chosen($rows; "openai-codex"; "5h"; "core")) as $cx5
		| (chosen($rows; "openai-codex"; "7d"; "core")) as $cx7
		| [
			provider_line("C"; $cl5; $cl7; $fable),
			provider_line("X"; $cx5; $cx7; null)
		]
		| join(" ")
		| .[0:$max_line_chars]
		| select(length > 0)
	' <<<"$response" 2>/dev/null
}

active_vault_id() {
  local first selected="" state_raw="" is_disabled=0
  first="$(jq -r '.[0].id // empty | strings' "$manifest" 2>/dev/null)"

  if [[ -r "$selection_state" ]]; then
    state_raw="$(<"$selection_state")"
    if jq -e 'type == "object"' <<<"$state_raw" >/dev/null 2>&1; then
      selected="$(jq -r '.selected // empty | strings' <<<"$state_raw" 2>/dev/null)"
      if [[ -n "$selected" ]] && jq -e --arg id "$selected" \
        '(.disabled // []) | index($id) != null' <<<"$state_raw" >/dev/null 2>&1; then
        is_disabled=1
      fi
    else
      selected="${state_raw#"${state_raw%%[![:space:]]*}"}"
      selected="${selected%"${selected##*[![:space:]]}"}"
    fi
  fi

  if [[ -z "$selected" || $is_disabled -eq 1 ]] ||
    ! jq -e --arg id "$selected" 'any(.[]; .id == $id)' "$manifest" >/dev/null 2>&1; then
    selected=$first
  fi
  printf '%s\n' "$selected"
}

publish_session() {
  local socket=$1 active_line=$2 seq=$3 workspace_json pane_json=""
  local workspace_id pane_id broker workspace_line
  declare -A workspace_broker=()

  if pane_json="$(HERDR_SOCKET_PATH="$socket" herdr pane list 2>/dev/null)"; then
    while IFS=$'\t' read -r workspace_id broker; do
      [[ -n "$workspace_id" && -n "$broker" ]] || continue
      workspace_broker[$workspace_id]=${broker%/}
    done < <(
      jq -r '
				(.result.panes // [])
				| group_by(.workspace_id)[]
				| .[0].workspace_id as $workspace
				| ([.[] | select(.agent == "omp") | .tokens.vault_broker // empty]
					| map(sub("/+$"; "")) | unique) as $brokers
				| select(($brokers | length) == 1)
				| [$workspace, $brokers[0]]
				| @tsv
			' <<<"$pane_json" 2>/dev/null
    )

    while IFS=$'\t' read -r pane_id broker; do
      [[ -n "$pane_id" && -n "$broker" ]] || continue
      broker=${broker%/}
      [[ -n "${usage_by_broker[$broker]:-}" ]] || continue
      HERDR_SOCKET_PATH="$socket" herdr pane report-metadata "$pane_id" \
        --source "$source_id" --token "usage=${usage_by_broker[$broker]}" \
        --ttl-ms "$ttl_ms" --seq "$seq" >/dev/null 2>&1 || true
    done < <(
      jq -r '.result.panes[]? | select((.tokens.vault_broker // "") != "")
				| [.pane_id, .tokens.vault_broker] | @tsv' <<<"$pane_json" 2>/dev/null
    )
  fi

  if workspace_json="$(HERDR_SOCKET_PATH="$socket" herdr workspace list 2>/dev/null)"; then
    while IFS= read -r workspace_id; do
      [[ -n "$workspace_id" ]] || continue
      if [[ -n "${workspace_broker[$workspace_id]:-}" ]]; then
        workspace_line=${usage_by_broker[${workspace_broker[$workspace_id]}]:-}
      else
        workspace_line=$active_line
      fi
      [[ -n "$workspace_line" ]] || continue
      HERDR_SOCKET_PATH="$socket" herdr workspace report-metadata "$workspace_id" \
        --source "$source_id" --token "usage=$workspace_line" \
        --ttl-ms "$ttl_ms" --seq "$seq" >/dev/null 2>&1 || true
    done < <(jq -r '.result.workspaces[]?.workspace_id // empty' <<<"$workspace_json" 2>/dev/null)
  fi
}

publish_cycle() {
  local id broker token_file line active_id active_line="" seq socket
  usage_by_id=()
  usage_by_broker=()
  [[ -r "$manifest" ]] || return 0
  jq -e 'type == "array" and length > 0' "$manifest" >/dev/null 2>&1 || return 0

  while IFS=$'\t' read -r id broker token_file; do
    [[ -n "$id" && -n "$broker" && -n "$token_file" ]] || continue
    broker=${broker%/}
    if line="$(usage_line "$broker" "$token_file")"; then
      usage_by_id[$id]=$line
      usage_by_broker[$broker]=$line
    fi
  done < <(
    jq -r '.[] | select(
			(.id | type) == "string" and
			(.brokerUrl | type) == "string" and .brokerUrl != "" and
			(.tokenFile | type) == "string" and .tokenFile != ""
		) | [.id, .brokerUrl, .tokenFile] | @tsv' "$manifest" 2>/dev/null
  )

  active_id="$(active_vault_id)"
  active_line=${usage_by_id[$active_id]:-}
  seq=$(date +%s)
  shopt -s nullglob
  for socket in "$herdr_sessions"/*/herdr.sock; do
    publish_session "$socket" "$active_line" "$seq"
  done
  shopt -u nullglob
}

while true; do
  publish_cycle || true
  [[ ${HERDR_USAGE_PUBLISHER_ONCE:-0} == 1 ]] && break
  sleep $((interval_seconds * 9 / 10 + RANDOM % (interval_seconds / 5 + 1)))
done
