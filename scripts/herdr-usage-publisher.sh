#!/usr/bin/env bash
set -uo pipefail

readonly interval_seconds=300
readonly ttl_ms=720000
readonly source_id="atyrode:usage"
readonly section_id="usage"
readonly max_rows=24

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
manifest="${CODE_AUTH_VAULTS_FILE:-$config_home/code/auth-vaults.json}"
vault_state="${CODE_AUTH_STATE:-$state_home/atyrode/code-auth-vault-state.json}"
herdr_sessions="$config_home/herdr/sessions"

warn() {
  printf 'herdr usage publisher: %s\n' "$*" >&2
}

fetch_endpoint() {
  local broker_url=$1 token=$2 endpoint=$3
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - -sf --max-time 15 --url "${broker_url%/}${endpoint}"
}

build_rows() {
  local vaults=$1 now_ms=$2
  jq -cn --argjson vaults "$vaults" --argjson now_ms "$now_ms" '
		def report_ids:
			[
				.metadata.identityKey?,
				.metadata.email?,
				.metadata.accountId?,
				.metadata.projectId?,
				.metadata.orgId?,
				.limits[]?.scope.accountId?,
				.limits[]?.scope.projectId?,
				.limits[]?.scope.orgId?
			]
			| map(select(type == "string" and length > 0) | ascii_downcase)
			| unique;
		def report_score($account):
			(.metadata.identityKey? // "" | ascii_downcase) as $report_key
			| (.metadata.email? // "" | ascii_downcase) as $report_email
			| ($account.identityKey | ascii_downcase) as $account_key
			| ($account.email | ascii_downcase) as $account_email
			| (report_ids) as $ids
			| (if $report_key != "" and $report_key == $account_key then 100 else 0 end)
				+ (if $account_email != "" and $report_email == $account_email then 50 else 0 end)
				+ (if $account_email != "" and ($ids | index($account_email)) != null then 20 else 0 end);
		def account_report($account; $vault):
			[
				$vault.usage.reports
				| to_entries[]
				| select(.value.provider == $account.provider)
				| (.value | report_score($account)) as $score
				| select($score > 0)
				| {report: .value, score: $score, order: .key}
			]
			| sort_by(.score * -1, .order) as $matches
			| [$vault.usage.reports[] | select(.provider == $account.provider)] as $reports
			| [$vault.snapshot.credentials[] | select(.provider == $account.provider)] as $credentials
			| if ($matches | length) > 0 then $matches[0].report
			  elif ($credentials | length) == 1 then $reports[0]
			  elif ($reports | length) == ($credentials | length) then $reports[$account.providerIndex]
			  else null
			  end;
		def used_fraction:
			if (.amount.usedFraction | type) == "number" then .amount.usedFraction
			elif (.amount.used | type) == "number" and
				(.amount.limit | type) == "number" and .amount.limit > 0
			then .amount.used / .amount.limit
			elif .amount.unit == "percent" and (.amount.used | type) == "number"
			then .amount.used / 100
			elif (.amount.remainingFraction | type) == "number"
			then 1 - .amount.remainingFraction
			else null
			end;
		def window_bucket:
			((.window.id // .scope.windowId // "") | ascii_downcase) as $id
			| (((.window.label // "") + " " + (.label // "")) | ascii_downcase) as $label
			| (.window.durationMs // 0) as $duration
			| if $id == "5h" or $duration == 18000000 or ($label | test("5[ -]?hour"))
			  then "5h"
			  elif $id == "7d" or $duration == 604800000 or ($label | test("7[ -]?day"))
			  then "7d"
			  else null
			  end;
		def window_variant:
			(
				((.scope.tier // "") + " " + (.label // "") + " " + (.window.label // ""))
				| ascii_downcase
			) as $kind
			| if ($kind | contains("fable")) then "fable"
			  elif ($kind | contains("spark")) then "spark"
			  else "core"
			  end;
		def window_class:
			(window_variant) as $variant
			| (window_bucket) as $bucket
			| if $variant == "fable" then {rank: 2, name: "fable"}
			  elif $variant == "spark" and $bucket == "5h" then {rank: 3, name: "sp 5h"}
			  elif $variant == "spark" and $bucket == "7d" then {rank: 4, name: "sp 7d"}
			  elif $variant == "core" and $bucket == "5h" then {rank: 0, name: "5h"}
			  elif $variant == "core" and $bucket == "7d" then {rank: 1, name: "7d"}
			  else null
			  end;
		def countdown($resets_at; $now_ms):
			((($resets_at - $now_ms) / 1000) | floor) as $raw_seconds
			| ([$raw_seconds, 0] | max) as $seconds
			| if $seconds >= 86400 then
				"\(($seconds / 86400) | floor)d\((($seconds % 86400) / 3600) | floor)h"
			  elif $seconds >= 3600 then
				"\(($seconds / 3600) | floor)h\((($seconds % 3600) / 60) | floor)m"
			  else
				"\(($seconds / 60) | floor)m"
			  end;
		def nibble:
			"0123456789abcdef"[.:.+1];
		def hex2($value):
			(($value / 16) | floor | nibble) + (($value % 16) | floor | nibble);
		def fill_color($pct):
			(
				if $pct <= 50 then {r: 90 + 3 * $pct, g: 200}
				else {r: 235, g: 200 - 3 * ($pct - 50)}
				end
			) as $color
			| ([235, $color.r] | min) as $r
			| ([60, $color.g] | max) as $g
			| "#" + hex2($r) + hex2($g) + "46";
		[
			$vaults[] as $vault
			| $vault.snapshot.credentials as $credentials
			| $credentials
			| to_entries[]
			| . as $entry
			| $entry.value as $credential
			| select(
				($credential.provider == "anthropic" or $credential.provider == "openai-codex") and
				($credential.identityKey | type) == "string" and
				$credential.identityKey != ""
			)
			| {
				provider: $credential.provider,
				identityKey: $credential.identityKey,
				email: (
					if ($credential.email | type) == "string" then $credential.email else "" end
				),
				vaultOrder: $vault.order,
				vaultLabel: $vault.label,
				credentialOrder: $entry.key,
				providerIndex: (
					[
						$credentials[0:$entry.key][]
						| select(.provider == $credential.provider)
					]
					| length
				)
			}
		] as $occurrences
		| [
			$occurrences
			| sort_by(.provider, .identityKey)
			| group_by([.provider, .identityKey])[]
			| sort_by(.vaultOrder, .credentialOrder) as $group
			| $group[0] as $first
			| ([$group[].email | select(type == "string" and length > 0)][0] // "") as $email
			| ($group | map(.vaultOrder) | unique | length) as $vault_count
			| {
				provider: $first.provider,
				identityKey: $first.identityKey,
				email: $email,
				firstVaultOrder: $first.vaultOrder,
				firstCredentialOrder: $first.credentialOrder,
				providerIndex: $first.providerIndex,
				accountName: (
					if $vault_count == 1 then $first.vaultLabel
					elif $email != "" then ($email | split("@")[0] | ascii_downcase)
					else $first.identityKey[0:8]
					end
				)
			}
		]
		| sort_by(
			(if .provider == "anthropic" then 0 else 1 end),
			.firstVaultOrder,
			.firstCredentialOrder
		) as $accounts
		| [
			$accounts[] as $account
			| ($vaults | map(select(.order == $account.firstVaultOrder))[0]) as $vault
			| account_report($account; $vault) as $report
			| select($report != null)
			| $report.limits
			| to_entries[]
			| . as $limit_entry
			| ($limit_entry.value | used_fraction) as $raw_fraction
			| select(($raw_fraction | type) == "number")
			| ($limit_entry.value | window_class) as $class
			| select($class != null)
			| ([0, $raw_fraction] | max | [1, .] | min) as $fraction
			| (($fraction * 100 + 0.5) | floor) as $pct
			| {
				accountOrder: (if $account.provider == "anthropic" then 0 else 1 end),
				vaultOrder: $account.firstVaultOrder,
				credentialOrder: $account.firstCredentialOrder,
				windowOrder: $class.rank,
				limitOrder: $limit_entry.key,
				row: {
					bar: {
						fraction: $fraction,
						title: ($account.accountName + " " + $class.name),
						label: (
							($pct | tostring) + "%" +
							(
								if ($limit_entry.value.window.resetsAt | type) == "number"
								then " ↻" + countdown($limit_entry.value.window.resetsAt; $now_ms)
								else ""
								end
							)
						),
						fill: fill_color($pct),
						empty: "#78829b"
					}
				}
			}
		]
		| sort_by(
			.accountOrder,
			.vaultOrder,
			.credentialOrder,
			.windowOrder,
			.limitOrder
		)
		| map(.row)
	'
}

publish_cycle() {
  local disabled_json='[]' encoded order id label broker_url token_file
  local token mode snapshot_raw usage_raw snapshot usage record
  local vaults rows payload socket now_ms seq row_count
  local -a vault_records=()

  [[ -r "$manifest" ]] || return 0
  jq -e 'type == "array" and length > 0' "$manifest" >/dev/null 2>&1 || return 0

  if [[ -r "$vault_state" ]]; then
    disabled_json="$(
      jq -ce '
				if type == "object" and (.disabled | type) == "array"
				then [.disabled[] | select(type == "string")]
				else []
				end
			' "$vault_state" 2>/dev/null
    )" || disabled_json='[]'
  fi

  while IFS= read -r encoded; do
    order="$(jq -rn --arg value "$encoded" '$value | @base64d | fromjson | .order')"
    id="$(jq -rn --arg value "$encoded" '$value | @base64d | fromjson | .id')"
    label="$(jq -rn --arg value "$encoded" '$value | @base64d | fromjson | .label')"
    broker_url="$(jq -rn --arg value "$encoded" '$value | @base64d | fromjson | .brokerUrl')"
    token_file="$(jq -rn --arg value "$encoded" '$value | @base64d | fromjson | .tokenFile')"

    [[ -f "$token_file" && -r "$token_file" ]] || {
      warn "skipping vault $id: tokenFile is not a readable regular file"
      continue
    }
    mode="$(stat -Lc '%a' -- "$token_file" 2>/dev/null)" || continue
    [[ $mode == 600 ]] || {
      warn "skipping vault $id: tokenFile mode must be 0600"
      continue
    }
    token="$(<"$token_file")"
    [[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || {
      warn "skipping vault $id: tokenFile content is invalid"
      continue
    }

    snapshot_raw="$(fetch_endpoint "$broker_url" "$token" "/v1/snapshot")" || {
      warn "skipping vault $id: snapshot broker request failed"
      continue
    }
    usage_raw="$(fetch_endpoint "$broker_url" "$token" "/v1/usage")" || {
      warn "skipping vault $id: usage broker request failed"
      continue
    }

    snapshot="$(
      jq -ce '
				.credentials as $credentials
				| select(($credentials | type) == "array")
				| {
					credentials: [
						$credentials[]?
						| select(
							(.provider == "anthropic" or .provider == "openai-codex") and
							(.identityKey | type) == "string" and
							.identityKey != ""
						)
						| {
							provider,
							identityKey,
							email: (
								if (.credential.email | type) == "string"
								then .credential.email
								else ""
								end
							)
						}
					]
				}
			' <<<"$snapshot_raw" 2>/dev/null
    )" || {
      warn "skipping vault $id: snapshot response is invalid"
      continue
    }
    usage="$(
      jq -ce '
				(if type == "array" then . else .reports end) as $reports
				| select(($reports | type) == "array")
				| {
					reports: [
						$reports[]?
						| select(.provider == "anthropic" or .provider == "openai-codex")
						| {
							provider,
							metadata: {
								identityKey: .metadata.identityKey?,
								email: .metadata.email?,
								accountId: .metadata.accountId?,
								projectId: .metadata.projectId?,
								orgId: .metadata.orgId?
							},
							limits: [
								.limits[]?
								| {
									label: (
										if (.label | type) == "string" then .label else "" end
									),
									scope: {
										tier: .scope.tier?,
										windowId: .scope.windowId?,
										accountId: .scope.accountId?,
										projectId: .scope.projectId?,
										orgId: .scope.orgId?
									},
									amount: {
										usedFraction: .amount.usedFraction?,
										used: .amount.used?,
										limit: .amount.limit?,
										remainingFraction: .amount.remainingFraction?,
										unit: .amount.unit?
									},
									window: {
										id: .window.id?,
										label: .window.label?,
										durationMs: .window.durationMs?,
										resetsAt: .window.resetsAt?
									}
								}
							]
						}
					]
				}
			' <<<"$usage_raw" 2>/dev/null
    )" || {
      warn "skipping vault $id: usage response is invalid"
      continue
    }

    record="$(
      jq -cn \
        --argjson order "$order" \
        --arg id "$id" \
        --arg label "$label" \
        --argjson snapshot "$snapshot" \
        --argjson usage "$usage" \
        '{order: $order, id: $id, label: $label, snapshot: $snapshot, usage: $usage}'
    )" || continue
    vault_records+=("$record")
  done < <(
    jq -cr --argjson disabled "$disabled_json" '
			to_entries[]
			| . as $entry
			| .value as $vault
			| select(
				($vault.id | type) == "string" and
				$vault.id != "" and
				($vault.brokerUrl | type) == "string" and
				$vault.brokerUrl != "" and
				($vault.tokenFile | type) == "string" and
				$vault.tokenFile != "" and
				(
					$entry.key == 0 or
					(($disabled | index($vault.id)) == null)
				)
			)
			| {
				order: $entry.key,
				id: $vault.id,
				label: (
					if ($vault.label | type) == "string" and $vault.label != ""
					then $vault.label
					else $vault.id
					end
				),
				brokerUrl: $vault.brokerUrl,
				tokenFile: $vault.tokenFile
			}
			| @base64
		' "$manifest" 2>/dev/null
  )

  ((${#vault_records[@]} > 0)) || return 0
  vaults="$(printf '%s\n' "${vault_records[@]}" | jq -sc '.')" || return 0
  now_ms="$(date +%s%3N)"
  [[ $now_ms =~ ^[0-9]+$ ]] || return 0
  rows="$(build_rows "$vaults" "$now_ms")" || return 0
  row_count="$(jq -r 'length' <<<"$rows")" || return 0
  if ((row_count > max_rows)); then
    warn "generated $row_count rows; publishing only the first $max_rows"
    rows="$(jq -c --argjson max "$max_rows" '.[0:$max]' <<<"$rows")" || return 0
    row_count=$max_rows
  fi
  ((row_count > 0)) || return 0

  seq=$((now_ms / 1000))
  payload="$(
    jq -cn \
      --arg section_id "$section_id" \
      --arg source "$source_id" \
      --argjson seq "$seq" \
      --argjson ttl_ms "$ttl_ms" \
      --argjson rows "$rows" \
      '{
				section_id: $section_id,
				source: $source,
				seq: $seq,
				ttl_ms: $ttl_ms,
				rows: $rows
			}'
  )" || return 0

  shopt -s nullglob
  for socket in "$herdr_sessions"/*/herdr.sock; do
    printf '%s\n' "$payload" |
      HERDR_SOCKET_PATH="$socket" herdr sidebar report-section --stdin >/dev/null 2>&1 || true
  done
  shopt -u nullglob
}

while true; do
  publish_cycle || true
  [[ ${HERDR_USAGE_PUBLISHER_ONCE:-0} == 1 ]] && break
  sleep $((interval_seconds * 9 / 10 + RANDOM % (interval_seconds / 5 + 1)))
done
