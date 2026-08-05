#!/usr/bin/env bash
# Test functions are dispatched by name through run_check.
# shellcheck disable=SC2329
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM_DIR=${HARNESS_PLATFORM_CHART:?HARNESS_PLATFORM_CHART must point to an extracted Harness Platform chart}
GENERATOR="$ROOT/scripts/generate-gateway-api"
INSPECTOR_CHART="$ROOT/tests/manifest-inspector"
FIXTURE_CHART="$ROOT/tests/fixtures/source-chart"
IGNORING_CUSTOM_CHART="$ROOT/tests/fixtures/custom-chart-ignores-inventory"
FIXTURE_VALUES="$ROOT/tests/fixtures/source-all.yaml"
PLATFORM_VALUES="$ROOT/tests/fixtures/platform-values.yaml"
VALUES_FILE="$ROOT/values.yaml"
VALUES_BASE_FILE="$ROOT/values-base.yaml"
RELEASE_NAMESPACE=harness-contract-test
RELEASE_NAME=harness-contract
KUBE_VERSION=1.34.0
REGEX_ORDERING_ACK=--allow-implementation-specific-regex-ordering
TAB=$'\t'

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-gateway-contract.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT HUP INT TERM

failures=0

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  local context=$3
  if [[ "$expected" != "$actual" ]]; then
    fail "$context: expected [$expected], got [$actual]"
  fi
}

assert_empty() {
  local file=$1
  local context=$2
  if [[ -s "$file" ]]; then
    fail "$context: expected empty output"
  fi
}

assert_line() {
  local file=$1
  local line=$2
  local context=$3
  if ! grep -Fqx -- "$line" "$file"; then
    fail "$context: missing TSV record [$line]"
  fi
}

record_count() {
  local file=$1
  local record_type=$2
  awk -F '\t' -v wanted="$record_type" '$1 == wanted { count++ } END { print count + 0 }' "$file"
}

resource_count() {
  local file=$1
  local kind=$2
  local name=${3:-}
  awk -F '\t' -v wanted_kind="$kind" -v wanted_name="$name" '
    $1 == "DOC" && $3 == wanted_kind && (wanted_name == "" || $5 == wanted_name) { count++ }
    END { print count + 0 }
  ' "$file"
}

inspect_manifest() {
  local manifest=$1
  local output=$2
  local helm_output="${output}.helm"
  helm template manifest-inspector "$INSPECTOR_CHART" \
    --set-file "manifest=$manifest" \
    --set-string targetListenerSet=harness-listeners >"$helm_output"
  awk 'index($0, "#INSPECT\t") == 1 { sub(/^#INSPECT\t/, ""); print }' \
    "$helm_output" >"$output"
}

inspect_document() {
  local document=$1
  local output=$2
  local helm_output="${output}.helm"
  helm template manifest-inspector "$INSPECTOR_CHART" \
    --set-file "manifest=$document" \
    --set-string mode=document >"$helm_output"
  awk 'index($0, "#INSPECT\t") == 1 { sub(/^#INSPECT\t/, ""); print }' \
    "$helm_output" >"$output"
}

render_source() {
  local chart=$1
  local values=$2
  local output=$3
  helm template "$RELEASE_NAME" "$chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --no-hooks \
    --kube-version "$KUBE_VERSION" \
    --values "$values" \
    --set global.gatewayAPI.enabled=false >"$output"
}

generate_chart() {
  local source_chart=$1
  local values=$2
  local output_chart=$3
  local log_prefix=$4
  shift 4
  bash "$GENERATOR" \
    --harness-chart "$source_chart" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$@" \
    --values "$values" >"${log_prefix}.stdout" 2>"${log_prefix}.stderr"
}

render_generated() {
  local chart=$1
  local output=$2
  shift 2
  helm template harness-gateway-api "$chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$chart/values-base.yaml" "$@" >"$output"
}

assert_ingress_route_parity() {
  local source_inspection=$1
  local generated_inspection=$2
  local context=$3
  local source_tuples="$TEST_TMP/${context}-ingress-tuples.tsv"
  local route_tuples="$TEST_TMP/${context}-route-tuples.tsv"

  awk -F '\t' '$1 == "INGRESS_BACKEND" { print $2 "\t" $3 "\t" $4 "\t" $5 }' \
    "$source_inspection" | LC_ALL=C sort -u >"$source_tuples"
  awk -F '\t' '$1 == "ROUTE_BACKEND" { path=$4; sub(/^\(\?i\)/, "", path); print $3 "\t" path "\t" $5 "\t" $6 }' \
    "$generated_inspection" | LC_ALL=C sort -u >"$route_tuples"

  [[ -s "$source_tuples" ]] || fail "$context: source Ingress tuple set is empty"
  if ! cmp -s "$source_tuples" "$route_tuples"; then
    printf '    Missing generated route tuples (first 10):\n' >&2
    comm -23 "$source_tuples" "$route_tuples" | sed -n '1,10p' >&2
    printf '    Extra generated route tuples (first 10):\n' >&2
    comm -13 "$source_tuples" "$route_tuples" | sed -n '1,10p' >&2
    fail "$context: Ingress and HTTPRoute backend contracts differ"
  fi
}

assert_tls_parity() {
  local source_inspection=$1
  local generated_inspection=$2
  local context=$3

  awk -F '\t' '$1 == "INGRESS_TLS" { print $3 "\t" $4 }' \
    "$source_inspection" | LC_ALL=C sort -u >"$TEST_TMP/${context}-ingress-tls.tsv"
  awk -F '\t' '$1 == "LISTENER" { print $4 "\t" $7 }' \
    "$generated_inspection" | LC_ALL=C sort -u >"$TEST_TMP/${context}-listener-tls.tsv"
  cmp -s "$TEST_TMP/${context}-ingress-tls.tsv" "$TEST_TMP/${context}-listener-tls.tsv" || \
    fail "$context: Listener host/TLS Secret contract differs from rendered Ingresses"

  awk -F '\t' '$1 == "INGRESS_TLS" { print $4 }' \
    "$source_inspection" | LC_ALL=C sort -u >"$TEST_TMP/${context}-ingress-secrets.tsv"
  awk -F '\t' '$1 == "GRANT_TO" && $4 == "Secret" { print $5 }' \
    "$generated_inspection" | LC_ALL=C sort -u >"$TEST_TMP/${context}-grant-secrets.tsv"
  cmp -s "$TEST_TMP/${context}-ingress-secrets.tsv" "$TEST_TMP/${context}-grant-secrets.tsv" || \
    fail "$context: ReferenceGrant Secret contract differs from rendered Ingresses"
}

assert_parent_contract() {
  local inspection=$1
  local context=$2
  local route_count parent_count
  route_count=$(record_count "$inspection" ROUTE_META)
  parent_count=$(record_count "$inspection" ROUTE_PARENT)
  assert_equal "$route_count" "$parent_count" "$context route/parent count"
  awk -F '\t' -v namespace="$RELEASE_NAMESPACE" '
    $1 == "ROUTE_META" && $4 > 16 { exit 1 }
    $1 == "ROUTE_PARENT" &&
      ($3 != namespace || $4 != "gateway.networking.k8s.io" ||
       $5 != "ListenerSet" || $6 != "harness-listeners" ||
       $7 != namespace || $8 == "") { exit 1 }
  ' "$inspection" || fail "$context: invalid ListenerSet ParentReference or more than 16 rules"
}

assert_filter_references() {
  local inspection=$1
  local context=$2
  awk -F '\t' '$1 == "DOC" && $3 == "HTTPRouteFilter" { print $5 }' \
    "$inspection" | LC_ALL=C sort -u >"$TEST_TMP/${context}-filters.tsv"
  awk -F '\t' '$1 == "ROUTE_FILTER" { print $7 }' \
    "$inspection" | LC_ALL=C sort -u >"$TEST_TMP/${context}-filter-refs.tsv"
  cmp -s "$TEST_TMP/${context}-filters.tsv" "$TEST_TMP/${context}-filter-refs.tsv" || \
    fail "$context: generated HTTPRouteFilters and ExtensionRefs differ"
}

assert_path_match_parity() {
  local source_inspection=$1
  local generated_inspection=$2
  local context=$3
  local source_matches="$TEST_TMP/${context}-source-semantic-matches.tsv"
  local generated_matches="$TEST_TMP/${context}-generated-semantic-matches.tsv"

  awk -F '\t' '$1 == "INGRESS_SEMANTIC_MATCH" {
    print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7
  }' "$source_inspection" | LC_ALL=C sort -u >"$source_matches"
  awk -F '\t' '$1 == "ROUTE_SEMANTIC_MATCH" {
    print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7
  }' "$generated_inspection" | LC_ALL=C sort -u >"$generated_matches"

  [[ -s "$source_matches" ]] || fail "$context: source semantic match set is empty"
  if ! cmp -s "$source_matches" "$generated_matches"; then
    printf '    Missing generated semantic matches (first 10):\n' >&2
    comm -23 "$source_matches" "$generated_matches" | sed -n '1,10p' >&2
    printf '    Extra generated semantic matches (first 10):\n' >&2
    comm -13 "$source_matches" "$generated_matches" | sed -n '1,10p' >&2
    fail "$context: path match type/value and backend associations differ"
  fi
}

assert_rewrite_parity() {
  local source_inspection=$1
  local generated_inspection=$2
  local context=$3
  local source_rewrites="$TEST_TMP/${context}-source-rewrites.tsv"
  local generated_rewrites="$TEST_TMP/${context}-generated-rewrites.tsv"

  awk -F '\t' '$1 == "INGRESS_REWRITE" {
    print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
  }' "$source_inspection" | LC_ALL=C sort -u >"$source_rewrites"
  awk -F '\t' '$1 == "ROUTE_REWRITE" {
    print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
  }' "$generated_inspection" | LC_ALL=C sort -u >"$generated_rewrites"

  if ! cmp -s "$source_rewrites" "$generated_rewrites"; then
    printf '    Missing generated rewrite associations (first 10):\n' >&2
    comm -23 "$source_rewrites" "$generated_rewrites" | sed -n '1,10p' >&2
    printf '    Extra generated rewrite associations (first 10):\n' >&2
    comm -13 "$source_rewrites" "$generated_rewrites" | sed -n '1,10p' >&2
    fail "$context: rewrite path/pattern/substitution associations differ"
  fi
}

assert_timeout_policy_parity() {
  local source_inspection=$1
  local generated_inspection=$2
  local context=$3
  local issues="$TEST_TMP/${context}-timeout-policy-issues.txt"

  awk -F '\t' '
    FNR == NR {
      if ($1 == "INGRESS_TIMEOUT") {
        source_timeout[$2]=$3
        source_timeout_count[$2]++
      }
      next
    }
    $1 == "ROUTE_SOURCE" {
      route_source[$2]=$3
      route_source_count[$2]++
    }
    $1 == "ROUTE_MATCH" { route_match_count[$2]++ }
    $1 == "ROUTE_TIMEOUT" {
      route_timeout_count[$2]++
      if ($4 != "0s" || $5 != "0s") {
        invalid_deadline[$2]=1
      }
    }
    $1 == "BACKEND_TRAFFIC_POLICY" {
      policy_count[$5]++
      policy_timeout[$5]=$6
      if ($3 != "gateway.networking.k8s.io" || $4 != "HTTPRoute") {
        invalid_target[$5]=1
      }
    }
    END {
      for (ingress in source_timeout_count) {
        if (source_timeout_count[ingress] != 1) {
          print "source Ingress " ingress " emitted duplicate timeout expectations"
        }
      }
      for (route in route_source) {
        ingress=route_source[route]
        route_seen_for_ingress[ingress]=1
        expected=(ingress in source_timeout) ? source_timeout[ingress] : ""
        if (route_source_count[route] != 1) {
          print "HTTPRoute " route " has duplicate source associations"
        }
        if (expected != "") {
          if (policy_count[route] != 1) {
            print "HTTPRoute " route " expected exactly one timeout policy, got " (policy_count[route] + 0)
          }
          if (policy_timeout[route] != expected) {
            print "HTTPRoute " route " expected policy timeout " expected ", got " policy_timeout[route]
          }
          if (route_match_count[route] != route_timeout_count[route]) {
            print "HTTPRoute " route " does not disable total deadlines on every match"
          }
          if (invalid_deadline[route]) {
            print "HTTPRoute " route " does not use request=0s and backendRequest=0s"
          }
          if (invalid_target[route]) {
            print "HTTPRoute " route " policy has an invalid target reference"
          }
        } else {
          if (policy_count[route] != 0) {
            print "HTTPRoute " route " has an unexpected timeout policy"
          }
          if (route_timeout_count[route] != 0) {
            print "HTTPRoute " route " unexpectedly disables total deadlines"
          }
        }
      }
      for (ingress in source_timeout) {
        if (!(ingress in route_seen_for_ingress)) {
          print "timeout-bearing source Ingress " ingress " has no generated route"
        }
      }
      for (route in policy_count) {
        if (!(route in route_source)) {
          print "timeout policy targets unknown HTTPRoute " route
        }
      }
    }
  ' "$source_inspection" "$generated_inspection" >"$issues"

  if [[ -s "$issues" ]]; then
    sed -n '1,20p' "$issues" | sed 's/^/    /' >&2
    fail "$context: source timeout and BackendTrafficPolicy contracts differ"
  fi
}

assert_semantic_parity() {
  local source_inspection=$1
  local generated_inspection=$2
  local context=$3
  assert_path_match_parity "$source_inspection" "$generated_inspection" "$context"
  assert_rewrite_parity "$source_inspection" "$generated_inspection" "$context"
  assert_timeout_policy_parity "$source_inspection" "$generated_inspection" "$context"
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

sha256_file() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

platform_hash() {
  (
    cd "$PLATFORM_DIR"
    find . -type f ! -name '.DS_Store' -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s  %s\n' "$(sha256_file "$file")" "$file"
    done
  ) | sha256_stream
}

run_check() {
  local name=$1
  local function_name=$2
  local status
  printf -- '- %s ... ' "$name"
  set +e
  (set -e; "$function_name")
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    printf 'ok\n'
  else
    printf 'FAILED\n'
    failures=$((failures + 1))
  fi
}

check_values_minimality() {
  local default_inspection="$TEST_TMP/values-default.tsv"
  local base_inspection="$TEST_TMP/values-base.tsv"
  inspect_document "$VALUES_FILE" "$default_inspection"
  inspect_document "$VALUES_BASE_FILE" "$base_inspection"
  assert_equal \
    'JSON{"harnessGatewayOverlay":{"ciliumNetworkPolicy":{"enabled":false},"enabled":false}}' \
    "$(tr -d '\t' <"$default_inspection")" \
    'values.yaml contract'
  assert_equal \
    'JSON{"harnessGatewayOverlay":{"ciliumNetworkPolicy":{"enabled":false},"enabled":true}}' \
    "$(tr -d '\t' <"$base_inspection")" \
    'values-base.yaml contract'
}

check_fixture_full_contract() {
  local output_chart="$TEST_TMP/fixture-full-chart"
  local source_manifest="$TEST_TMP/fixture-full-source.yaml"
  local generated_manifest="$TEST_TMP/fixture-full-generated.yaml"
  local source_inspection="$TEST_TMP/fixture-full-source.tsv"
  local generated_inspection="$TEST_TMP/fixture-full-generated.tsv"

  generate_chart "$FIXTURE_CHART" "$FIXTURE_VALUES" "$output_chart" \
    "$TEST_TMP/fixture-full-generator" "$REGEX_ORDERING_ACK"
  render_source "$FIXTURE_CHART" "$FIXTURE_VALUES" "$source_manifest"
  render_generated "$output_chart" "$generated_manifest"
  inspect_manifest "$source_manifest" "$source_inspection"
  inspect_manifest "$generated_manifest" "$generated_inspection"

  grep -Fq 'different read and send inactivity timeouts' "$TEST_TMP/fixture-full-generator.stderr" || \
    fail 'timeout semantic warning is missing'
  assert_equal 4 "$(resource_count "$source_inspection" Ingress)" 'fixture Ingress count'
  assert_equal 4 "$(resource_count "$generated_inspection" HTTPRoute)" 'generated HTTPRoute count'
  assert_equal 1 "$(resource_count "$generated_inspection" ListenerSet harness-listeners)" 'ListenerSet count'
  assert_equal 2 "$(record_count "$generated_inspection" LISTENER)" 'listener count'
  assert_equal 1 "$(resource_count "$generated_inspection" HTTPRouteFilter)" 'rewrite filter count'
  assert_equal 1 "$(resource_count "$generated_inspection" BackendTrafficPolicy)" 'timeout policy count'
  assert_equal 1 "$(resource_count "$generated_inspection" ReferenceGrant allow-apps-gateway-tls)" 'ReferenceGrant count'
  assert_equal 0 "$(resource_count "$generated_inspection" CiliumNetworkPolicy)" 'default Cilium policy count'
  assert_line "$generated_inspection" \
    "LISTENER_PARENT${TAB}harness-listeners${TAB}gateway.networking.k8s.io${TAB}Gateway${TAB}apps-gateway${TAB}envoy-gateway-apps" \
    'central Gateway parent'
  assert_line "$generated_inspection" \
    "GRANT_FROM${TAB}allow-apps-gateway-tls${TAB}gateway.networking.k8s.io${TAB}Gateway${TAB}envoy-gateway-apps" \
    'ReferenceGrant source'
  assert_line "$generated_inspection" \
    "ROUTE_TIMEOUT${TAB}harness-api-465ee3d8-p1${TAB}/api${TAB}0s${TAB}0s" \
    'total timeout disablement'
  assert_line "$generated_inspection" \
    "BACKEND_TRAFFIC_POLICY${TAB}harness-api-465ee3d8-p1-idle-f04d5633${TAB}gateway.networking.k8s.io${TAB}HTTPRoute${TAB}harness-api-465ee3d8-p1${TAB}30s" \
    'Ingress inactivity timeout conversion'
  assert_line "$generated_inspection" \
    "ROUTE_BACKEND${TAB}looker-88816d11-p1${TAB}looker.example.invalid${TAB}/api${TAB}looker-api${TAB}19999" \
    'Looker API named Service port resolution'
  assert_line "$generated_inspection" \
    "ROUTE_BACKEND${TAB}looker-88816d11-p1${TAB}looker.example.invalid${TAB}/${TAB}looker-web${TAB}9999" \
    'Looker web named Service port resolution'
  grep -Fq "${TAB}(?i)/proxy(/|\$)(.*)${TAB}/\\2" "$generated_inspection" || \
    fail 'Envoy regular-expression rewrite contract is missing'
  awk -F '\t' '$1 == "ROUTE_BACKEND" && $6 !~ /^[0-9]+$/ { exit 1 }' "$generated_inspection" || \
    fail 'all generated backend ports must be numeric'
  for match_type in Exact PathPrefix RegularExpression; do
    if ! awk -F '\t' -v wanted="$match_type" \
      '$1 == "INGRESS_SEMANTIC_MATCH" && $4 == wanted { found=1 } END { exit found ? 0 : 1 }' \
      "$source_inspection"; then
      fail "fixture must exercise $match_type path conversion"
    fi
  done
  assert_ingress_route_parity "$source_inspection" "$generated_inspection" fixture-full
  assert_semantic_parity "$source_inspection" "$generated_inspection" fixture-full
  assert_tls_parity "$source_inspection" "$generated_inspection" fixture-full
  assert_parent_contract "$generated_inspection" fixture-full
  assert_filter_references "$generated_inspection" fixture-full
}

check_disabled_ingress_removal() {
  local output_chart="$TEST_TMP/fixture-disabled-chart"
  local values="$ROOT/tests/fixtures/source-optional-disabled.yaml"
  local source_manifest="$TEST_TMP/fixture-disabled-source.yaml"
  local generated_manifest="$TEST_TMP/fixture-disabled-generated.yaml"
  local source_inspection="$TEST_TMP/fixture-disabled-source.tsv"
  local generated_inspection="$TEST_TMP/fixture-disabled-generated.tsv"

  generate_chart "$FIXTURE_CHART" "$values" "$output_chart" \
    "$TEST_TMP/fixture-disabled-generator" "$REGEX_ORDERING_ACK"
  render_source "$FIXTURE_CHART" "$values" "$source_manifest"
  render_generated "$output_chart" "$generated_manifest"
  inspect_manifest "$source_manifest" "$source_inspection"
  inspect_manifest "$generated_manifest" "$generated_inspection"

  assert_equal 3 "$(resource_count "$source_inspection" Ingress)" 'disabled source Ingress count'
  assert_equal 3 "$(resource_count "$generated_inspection" HTTPRoute)" 'disabled generated route count'
  if grep -Fq 'harness-optional' "$generated_inspection"; then
    fail 'disabled Ingress must not leave an HTTPRoute or backend behind'
  fi
  if grep -Fq 'harness-optional' "$output_chart/generated/harness-gateway-inventory.json"; then
    fail 'disabled Ingress must not remain in the generated inventory'
  fi
  assert_ingress_route_parity "$source_inspection" "$generated_inspection" fixture-disabled
  assert_semantic_parity "$source_inspection" "$generated_inspection" fixture-disabled
}

check_deterministic_inventory() {
  local first="$TEST_TMP/deterministic-first"
  local second="$TEST_TMP/deterministic-second"
  generate_chart "$FIXTURE_CHART" "$FIXTURE_VALUES" "$first" \
    "$TEST_TMP/deterministic-first-generator" "$REGEX_ORDERING_ACK"
  generate_chart "$FIXTURE_CHART" "$FIXTURE_VALUES" "$second" \
    "$TEST_TMP/deterministic-second-generator" "$REGEX_ORDERING_ACK"
  cmp -s \
    "$first/generated/harness-gateway-inventory.json" \
    "$second/generated/harness-gateway-inventory.json" || \
    fail 'identical source renders must produce byte-identical inventories'

  render_generated "$first" "$TEST_TMP/deterministic-first.yaml"
  render_generated "$second" "$TEST_TMP/deterministic-second.yaml"
  cmp -s "$TEST_TMP/deterministic-first.yaml" "$TEST_TMP/deterministic-second.yaml" || \
    fail 'identical inventories must produce byte-identical Helm output'
}

check_empty_ingress_contract() {
  local values="$ROOT/tests/fixtures/source-empty.yaml"
  local output_chart="$TEST_TMP/fixture-empty-chart"
  local generated_manifest="$TEST_TMP/fixture-empty-generated.yaml"

  generate_chart "$FIXTURE_CHART" "$values" "$output_chart" "$TEST_TMP/fixture-empty-generator"
  render_generated "$output_chart" "$generated_manifest"
  if grep -Eq '^[[:space:]]*kind:[[:space:]]' "$generated_manifest"; then
    fail 'an environment with no rendered Ingresses must produce no Gateway API resources'
  fi
  grep -Fq '"listeners":[]' "$output_chart/generated/harness-gateway-inventory.json" || \
    fail 'empty inventory listeners contract is missing'
  grep -Fq '"routes":[]' "$output_chart/generated/harness-gateway-inventory.json" || \
    fail 'empty inventory routes contract is missing'
  grep -Fq '0 Ingresses, 0 listeners, 0 HTTPRoutes' "$TEST_TMP/fixture-empty-generator.stdout" || \
    fail 'empty generator summary is incorrect'
}

check_regex_ordering_requires_acknowledgment() {
  local output_chart="$TEST_TMP/fixture-regex-without-ack-chart"
  local stdout="$TEST_TMP/fixture-regex-without-ack.stdout"
  local stderr="$TEST_TMP/fixture-regex-without-ack.stderr"

  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    --values "$FIXTURE_VALUES" >"$stdout" 2>"$stderr"; then
    fail 'ambiguous regex ordering must fail without explicit acknowledgment'
  fi
  assert_empty "$stdout" 'unacknowledged regex ordering stdout'
  [[ ! -e "$output_chart" ]] || fail 'failed regex conversion must not publish an output chart'
  grep -Fq 'combines regular-expression and plain path matches whose ingress-nginx ordering cannot be preserved' \
    "$stderr" || fail 'regex-ordering failure must identify the semantic ambiguity'
  grep -Fq -- "$REGEX_ORDERING_ACK" "$stderr" || \
    fail 'regex-ordering failure must identify the explicit acknowledgment flag'
}

check_regex_acknowledgment_is_recorded() {
  local output_chart="$TEST_TMP/fixture-regex-ack-chart"
  local inventory="$output_chart/generated/harness-gateway-inventory.json"

  generate_chart "$FIXTURE_CHART" "$FIXTURE_VALUES" "$output_chart" \
    "$TEST_TMP/fixture-regex-ack-generator" "$REGEX_ORDERING_ACK"
  grep -Fq '"regexPrecedenceAcknowledged":true' "$inventory" || \
    fail 'explicit regex-ordering acknowledgment is missing from the inventory'
}

check_duplicate_timeout_contract_fails_closed() {
  local values="$ROOT/tests/fixtures/source-duplicate-timeout.yaml"
  local output_chart="$TEST_TMP/fixture-duplicate-timeout-chart"
  local stdout="$TEST_TMP/fixture-duplicate-timeout.stdout"
  local stderr="$TEST_TMP/fixture-duplicate-timeout.stderr"

  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$REGEX_ORDERING_ACK" \
    --values "$values" >"$stdout" 2>"$stderr"; then
    fail 'duplicate matches with different timeout semantics must fail generation'
  fi
  assert_empty "$stdout" 'duplicate timeout contract stdout'
  [[ ! -e "$output_chart" ]] || fail 'ambiguous duplicate must not publish an output chart'
  grep -Fq 'has an ambiguous duplicate RegularExpression match' "$stderr" || \
    fail 'duplicate timeout failure must identify the ambiguous match contract'
}

assert_source_resource_scan_failure() {
  local values=$1
  local stem=$2
  local expected=$3
  local output_chart="$TEST_TMP/${stem}-chart"
  local stdout="$TEST_TMP/${stem}.stdout"
  local stderr="$TEST_TMP/${stem}.stderr"

  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    --values "$values" >"$stdout" 2>"$stderr"; then
    fail "$stem: unexpected Gateway resource must fail source scanning"
  fi
  assert_empty "$stdout" "$stem stdout"
  [[ ! -e "$output_chart" ]] || fail "$stem: rejected source render must not publish an output chart"
  grep -Fq -- "$expected" "$stderr" || \
    fail "$stem: source-scan failure must identify the exact resource"
}

check_unexpected_gateway_resources_fail_source_scan() {
  assert_source_resource_scan_failure \
    "$ROOT/tests/fixtures/source-unexpected-gateway-api.yaml" \
    unexpected-gateway-api \
    'gateway.networking.k8s.io/v1 resource Gateway "unexpected-gateway"'
  assert_source_resource_scan_failure \
    "$ROOT/tests/fixtures/source-unexpected-envoy.yaml" \
    unexpected-envoy-gateway \
    'gateway.envoyproxy.io/v1alpha1 resource BackendTrafficPolicy "unexpected-backend-traffic-policy"'
}

check_unknown_annotation_fails_closed() {
  local values="$ROOT/tests/fixtures/source-unknown-annotation.yaml"
  local output_chart="$TEST_TMP/fixture-unknown-chart"
  local stdout="$TEST_TMP/fixture-unknown.stdout"
  local stderr="$TEST_TMP/fixture-unknown.stderr"
  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    --values "$values" >"$stdout" 2>"$stderr"; then
    fail 'unsupported NGINX annotation must fail generation'
  fi
  assert_empty "$stdout" 'unsupported annotation stdout'
  [[ ! -e "$output_chart" ]] || fail 'failed generation must not publish an output chart'
  grep -Fq 'unsupported NGINX annotation nginx.ingress.kubernetes.io/permanent-redirect' "$stderr" || \
    fail 'unsupported annotation error must identify the exact annotation'
}

check_invalid_regex_fails_closed() {
  local values="$ROOT/tests/fixtures/source-invalid-regex.yaml"
  local output_chart="$TEST_TMP/fixture-invalid-regex-chart"
  local stdout="$TEST_TMP/fixture-invalid-regex.stdout"
  local stderr="$TEST_TMP/fixture-invalid-regex.stderr"

  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$REGEX_ORDERING_ACK" \
    --values "$values" >"$stdout" 2>"$stderr"; then
    fail 'a PCRE-only Ingress path must fail RE2 conversion'
  fi
  assert_empty "$stdout" 'invalid regex stdout'
  [[ ! -e "$output_chart" ]] || fail 'invalid regex must not publish an output chart'
  grep -Fq 'error parsing regexp' "$stderr" || \
    fail 'invalid regex error must identify the RE2 compilation failure'
}

check_numeric_port_mismatch_is_visible() {
  local values="$ROOT/tests/fixtures/source-numeric-port-mismatch.yaml"
  local output_chart="$TEST_TMP/fixture-port-mismatch-chart"
  local generated_manifest="$TEST_TMP/fixture-port-mismatch-generated.yaml"
  local generated_inspection="$TEST_TMP/fixture-port-mismatch-generated.tsv"

  generate_chart "$FIXTURE_CHART" "$values" "$output_chart" "$TEST_TMP/fixture-port-mismatch-generator"
  grep -Fq 'references numeric port 8181 not exposed by rendered Service' \
    "$TEST_TMP/fixture-port-mismatch-generator.stderr" || \
    fail 'numeric Service-port mismatch must produce a specific warning'
  render_generated "$output_chart" "$generated_manifest"
  inspect_manifest "$generated_manifest" "$generated_inspection"
  assert_line "$generated_inspection" \
    "ROUTE_BACKEND${TAB}harness-optional-465ee3d8-p1${TAB}harness.example.invalid${TAB}/optional${TAB}harness-optional${TAB}8181" \
    'numeric Ingress port preservation'
}

check_ignored_inventory_fails_closed() {
  local output_chart="$TEST_TMP/fixture-ignored-inventory-chart"
  local stdout="$TEST_TMP/fixture-ignored-inventory.stdout"
  local stderr="$TEST_TMP/fixture-ignored-inventory.stderr"
  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$IGNORING_CUSTOM_CHART" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$REGEX_ORDERING_ACK" \
    --values "$FIXTURE_VALUES" >"$stdout" 2>"$stderr"; then
    fail 'a custom-chart .helmignore that excludes the inventory must fail generation'
  fi
  assert_empty "$stdout" 'ignored inventory stdout'
  [[ ! -e "$output_chart" ]] || fail 'failed inventory packaging must not publish an output chart'
  grep -Fq 'update the custom chart .helmignore' "$stderr" || \
    fail 'ignored inventory error must identify .helmignore remediation'
}

check_output_below_source_fails_closed() {
  local source_copy="$TEST_TMP/source-chart-copy"
  local output_chart="$source_copy/generated-output"
  local stdout="$TEST_TMP/output-below-source.stdout"
  local stderr="$TEST_TMP/output-below-source.stderr"

  cp -R "$FIXTURE_CHART" "$source_copy"
  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$source_copy" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$REGEX_ORDERING_ACK" \
    --values "$FIXTURE_VALUES" >"$stdout" 2>"$stderr"; then
    fail 'an output path inside the source custom chart must fail generation'
  fi
  assert_empty "$stdout" 'output-below-source stdout'
  [[ ! -e "$output_chart" ]] || fail 'rejected output path must not be created'
  grep -Fq 'output path must be outside the source custom chart' "$stderr" || \
    fail 'output-below-source error must explain the immutability boundary'

  local harness_copy="$TEST_TMP/harness-chart-copy"
  local harness_output="$harness_copy/generated-output"
  local harness_stdout="$TEST_TMP/output-below-harness.stdout"
  local harness_stderr="$TEST_TMP/output-below-harness.stderr"
  cp -R "$FIXTURE_CHART" "$harness_copy"
  if bash "$GENERATOR" \
    --harness-chart "$harness_copy" \
    --custom-chart "$ROOT" \
    --output-chart "$harness_output" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$REGEX_ORDERING_ACK" \
    --values "$FIXTURE_VALUES" >"$harness_stdout" 2>"$harness_stderr"; then
    fail 'an output path inside the source Harness chart must fail generation'
  fi
  assert_empty "$harness_stdout" 'output-below-Harness stdout'
  [[ ! -e "$harness_output" ]] || fail 'rejected Harness output path must not be created'
  grep -Fq 'output path must be outside the source Harness chart' "$harness_stderr" || \
    fail 'output-below-Harness error must explain the immutability boundary'
}

check_render_capabilities_are_recorded() {
  local output_chart="$TEST_TMP/fixture-capabilities-chart"
  local inventory="$output_chart/generated/harness-gateway-inventory.json"
  local missing_output="$TEST_TMP/fixture-missing-kube-version-chart"
  local missing_stdout="$TEST_TMP/fixture-missing-kube-version.stdout"
  local missing_stderr="$TEST_TMP/fixture-missing-kube-version.stderr"
  local expected_helm_version

  if bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$missing_output" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --values "$FIXTURE_VALUES" >"$missing_stdout" 2>"$missing_stderr"; then
    fail 'generation without an explicit Kubernetes version must fail'
  fi
  assert_empty "$missing_stdout" 'missing Kubernetes version stdout'
  [[ ! -e "$missing_output" ]] || fail 'missing Kubernetes version must not publish an output chart'
  grep -Fq -- '--kube-version is required' "$missing_stderr" || \
    fail 'missing Kubernetes version error must identify the required option'

  bash "$GENERATOR" \
    --harness-chart "$FIXTURE_CHART" \
    --custom-chart "$ROOT" \
    --output-chart "$output_chart" \
    --namespace "$RELEASE_NAMESPACE" \
    --release-name "$RELEASE_NAME" \
    --kube-version "$KUBE_VERSION" \
    "$REGEX_ORDERING_ACK" \
    --api-versions example.io/v1 \
    --api-versions example.io/v1/Example \
    --values "$FIXTURE_VALUES" >"$TEST_TMP/fixture-capabilities.stdout" \
    2>"$TEST_TMP/fixture-capabilities.stderr"
  grep -Fq "\"kubeVersion\":\"$KUBE_VERSION\"" "$inventory" || \
    fail 'requested Kubernetes render version is missing from the inventory'
  expected_helm_version=$(helm version --template '{{ .Version }}')
  grep -Fq "\"helmVersion\":\"$expected_helm_version\"" "$inventory" || \
    fail 'actual Helm render version is missing from the inventory'
  grep -Fq '"apiVersions":["example.io/v1","example.io/v1/Example"]' "$inventory" || \
    fail 'requested API capabilities are missing from the inventory'
}

check_cilium_opt_in() {
  local output_chart="$TEST_TMP/fixture-cilium-chart"
  local manifest="$TEST_TMP/fixture-cilium.yaml"
  local inspection="$TEST_TMP/fixture-cilium.tsv"
  generate_chart "$FIXTURE_CHART" "$FIXTURE_VALUES" "$output_chart" \
    "$TEST_TMP/fixture-cilium-generator" "$REGEX_ORDERING_ACK"
  render_generated "$output_chart" "$manifest" \
    --set harnessGatewayOverlay.ciliumNetworkPolicy.enabled=true
  inspect_manifest "$manifest" "$inspection"
  assert_equal 1 "$(resource_count "$inspection" CiliumNetworkPolicy allow-envoy-gateway)" 'Cilium policy count'
  assert_line "$inspection" \
    "CILIUM${TAB}allow-envoy-gateway${TAB}{}${TAB}false${TAB}{\"k8s:gateway.envoyproxy.io/owning-gateway-name\":\"apps-gateway\",\"k8s:gateway.envoyproxy.io/owning-gateway-namespace\":\"envoy-gateway-apps\",\"k8s:io.kubernetes.pod.namespace\":\"envoy-gateway-apps\"}" \
    'Cilium source identity contract'
}

check_official_platform_contract() {
  local output_chart="$TEST_TMP/platform-generated-chart"
  local source_manifest="$TEST_TMP/platform-source.yaml"
  local generated_manifest="$TEST_TMP/platform-generated.yaml"
  local source_inspection="$TEST_TMP/platform-source.tsv"
  local generated_inspection="$TEST_TMP/platform-generated.tsv"

  generate_chart "$PLATFORM_DIR" "$PLATFORM_VALUES" "$output_chart" \
    "$TEST_TMP/platform-generator" "$REGEX_ORDERING_ACK"
  render_source "$PLATFORM_DIR" "$PLATFORM_VALUES" "$source_manifest"
  render_generated "$output_chart" "$generated_manifest"
  inspect_manifest "$source_manifest" "$source_inspection"
  inspect_manifest "$generated_manifest" "$generated_inspection"

  assert_equal 0 "$(resource_count "$source_inspection" HTTPRoute)" 'native Harness HTTPRoute count'
  assert_equal 0 "$(resource_count "$source_inspection" GRPCRoute)" 'native Harness GRPCRoute count'
  [[ "$(resource_count "$source_inspection" Ingress)" -gt 0 ]] || \
    fail 'official Harness 0.42.1 render must contain Ingresses'
  [[ "$(resource_count "$generated_inspection" HTTPRoute)" -gt 0 ]] || \
    fail 'official Harness 0.42.1 conversion must contain HTTPRoutes'
  [[ "$(resource_count "$generated_inspection" HTTPRouteFilter)" -gt 0 ]] || \
    fail 'official Harness 0.42.1 conversion must exercise Envoy rewrite filters'
  [[ "$(resource_count "$generated_inspection" BackendTrafficPolicy)" -gt 0 ]] || \
    fail 'official Harness 0.42.1 conversion must exercise Envoy idle-timeout policies'
  assert_equal 1 "$(resource_count "$generated_inspection" ListenerSet harness-listeners)" 'official ListenerSet count'
  assert_equal 1 "$(resource_count "$generated_inspection" ReferenceGrant allow-apps-gateway-tls)" 'official ReferenceGrant count'
  grep -Fq "INGRESS_BACKEND${TAB}looker.example.invalid" "$source_inspection" || \
    fail 'official source render must exercise the Looker Ingress'
  if ! awk -F '\t' '$1 == "ROUTE_BACKEND" { seen=1; if ($6 !~ /^[0-9]+$/) exit 1 } END { exit seen ? 0 : 1 }' "$generated_inspection"; then
    fail 'official route backends, including Looker named ports, must resolve to numbers'
  fi
  assert_ingress_route_parity "$source_inspection" "$generated_inspection" platform
  assert_semantic_parity "$source_inspection" "$generated_inspection" platform
  assert_tls_parity "$source_inspection" "$generated_inspection" platform
  assert_parent_contract "$generated_inspection" platform
  assert_filter_references "$generated_inspection" platform
}

[[ -x "$GENERATOR" ]] || fail 'scripts/generate-gateway-api must be executable'
[[ -f "$PLATFORM_DIR/Chart.yaml" ]] || fail 'HARNESS_PLATFORM_CHART has no Chart.yaml'
platform_digest_before=$(platform_hash)

run_check 'values expose only the two new overlay switches' check_values_minimality
run_check 'generator maps listeners, routes, filters, TLS grants and named ports' check_fixture_full_contract
run_check 'disabling an Ingress removes its generated HTTPRoute' check_disabled_ingress_removal
run_check 'identical environment input produces deterministic output' check_deterministic_inventory
run_check 'an environment without Ingresses produces no routing resources' check_empty_ingress_contract
run_check 'ambiguous regex ordering requires explicit acknowledgment' check_regex_ordering_requires_acknowledgment
run_check 'regex-ordering acknowledgment is recorded in the inventory' check_regex_acknowledgment_is_recorded
run_check 'duplicate matches with different timeouts fail closed' check_duplicate_timeout_contract_fails_closed
run_check 'unexpected Gateway and Envoy resources fail source scanning' check_unexpected_gateway_resources_fail_source_scan
run_check 'unknown NGINX annotations fail closed' check_unknown_annotation_fails_closed
run_check 'PCRE-only Ingress regex paths fail closed' check_invalid_regex_fails_closed
run_check 'numeric Ingress port mismatches remain visible' check_numeric_port_mismatch_is_visible
run_check 'an incompatible custom-chart .helmignore fails closed' check_ignored_inventory_fails_closed
run_check 'output paths inside either source chart fail closed' check_output_below_source_fails_closed
run_check 'render capabilities are recorded in the inventory' check_render_capabilities_are_recorded
run_check 'Cilium network policy remains an explicit opt-in' check_cilium_opt_in
run_check 'official Harness 0.42.1 Ingresses have complete route parity' check_official_platform_contract

printf -- '- tests do not modify the Harness Platform chart ... '
platform_digest_after=$(platform_hash)
if [[ "$platform_digest_before" == "$platform_digest_after" ]]; then
  printf 'ok\n'
else
  printf 'FAILED\n'
  printf '    Harness Platform chart content changed during the test run\n' >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\n18 contract checks passed\n'
  exit 0
fi

printf '\n%d contract check(s) failed\n' "$failures" >&2
exit 1
