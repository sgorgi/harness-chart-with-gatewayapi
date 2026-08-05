#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM_DIR=${HARNESS_PLATFORM_CHART:?HARNESS_PLATFORM_CHART must point to an extracted Harness Platform chart}
INSPECTOR_CHART="$ROOT/tests/manifest-inspector"
POST_RENDERER="$ROOT/scripts/listenerset-parentref-post-renderer"
VALUES_FILE="$ROOT/values.yaml"
VALUES_BASE_FILE="$ROOT/values-base.yaml"
PLUGIN_FILE="$ROOT/scripts/plugin.yaml"
RELEASE_NAMESPACE="harness-contract-test"
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
    --set-string "targetListenerSet=harness-listeners" >"$helm_output"
  awk 'index($0, "#INSPECT\t") == 1 { sub(/^#INSPECT\t/, ""); print }' "$helm_output" >"$output"
}

inspect_document() {
  local document=$1
  local output=$2
  local helm_output="${output}.helm"
  helm template manifest-inspector "$INSPECTOR_CHART" \
    --set-file "manifest=$document" \
    --set-string mode=document >"$helm_output"
  awk 'index($0, "#INSPECT\t") == 1 { sub(/^#INSPECT\t/, ""); print }' "$helm_output" >"$output"
}

render_overlay() {
  local looker=$1
  local cilium=$2
  local output=$3
  shift 3

  local command=(
    helm template harness-gateway-api "$ROOT"
    --namespace "$RELEASE_NAMESPACE"
    --values "$VALUES_BASE_FILE"
    --set global.ingress.enabled=true
    --set global.ingress.tls.enabled=true
    --set-string 'global.ingress.hosts[0]=harness.example.invalid'
    --set-string global.ingress.tls.secretName=harness-contract-tls
    --set global.gatewayAPI.enabled=true
    --set-string global.gatewayAPI.parentRef.name=harness-listeners
    --set-string "global.gatewayAPI.parentRef.namespace=$RELEASE_NAMESPACE"
    --set-string global.gatewayAPI.parentRef.sectionName=harness-https
    --set global.ng.enabled=true
    --set global.cg.enabled=false
    --set "global.ngcustomdashboard.enabled=$looker"
    --set "harnessGatewayOverlay.ciliumNetworkPolicy.enabled=$cilium"
  )
  if [[ "$looker" == true ]]; then
    command+=(
      --set-string 'looker.ingress.hosts[0]=looker.example.invalid'
      --set-string looker.ingress.tls.secretName=looker-contract-tls
    )
  fi
  command+=("$@")
  "${command[@]}" >"$output"
}

render_native() {
  local output=$1
  shift
  local command=(
    helm template harness "$PLATFORM_DIR"
    --namespace "$RELEASE_NAMESPACE"
    --set global.gatewayAPI.enabled=true
    --set global.ingress.enabled=true
    --set-string 'global.ingress.hosts[0]=harness.example.invalid'
    --set-string global.gatewayAPI.parentRef.name=harness-listeners
    --set-string global.gatewayAPI.parentRef.sectionName=harness-https
  )
  command+=("$@")
  "${command[@]}" >"$output"
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
  printf -- '- %s ... ' "$name"
  if (set -e; case "$function_name" in
      check_values_minimality) check_values_minimality ;;
      check_helm4_plugin_contract) check_helm4_plugin_contract ;;
      check_overlay_with_looker) check_overlay_with_looker ;;
      check_overlay_without_looker) check_overlay_without_looker ;;
      check_existing_service_overrides) check_existing_service_overrides ;;
      check_overlay_platform_contract) check_overlay_platform_contract ;;
      check_cilium_opt_in) check_cilium_opt_in ;;
      check_post_renderer_contract) check_post_renderer_contract ;;
      check_native_parent_refs) check_native_parent_refs ;;
      check_classic_only_not_silent) check_classic_only_not_silent ;;
      check_dynamic_ingress_parity) check_dynamic_ingress_parity ;;
      *) fail "unknown check function: $function_name" ;;
    esac); then
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

check_helm4_plugin_contract() {
  local inspection="$TEST_TMP/plugin.tsv"
  inspect_document "$PLUGIN_FILE" "$inspection"
  # The Helm plugin placeholder must remain literal in this assertion.
  # shellcheck disable=SC2016
  assert_equal \
    'JSON{"apiVersion":"v1","name":"harness-listenerset-parentref","runtime":"subprocess","runtimeConfig":{"platformCommand":[{"command":"${HELM_PLUGIN_DIR}/listenerset-parentref-post-renderer"}]},"type":"postrenderer/v1","version":"0.2.0"}' \
    "$(tr -d '\t' <"$inspection")" \
    'Helm 4 plugin contract'
  [[ -x "$POST_RENDERER" ]] || fail 'post-renderer must be executable'
}

check_overlay_with_looker() {
  local manifest="$TEST_TMP/overlay-looker.yaml"
  local inspection="$TEST_TMP/overlay-looker.tsv"
  render_overlay true false "$manifest"
  inspect_manifest "$manifest" "$inspection"

  assert_equal 1 "$(resource_count "$inspection" ListenerSet harness-listeners)" 'ListenerSet count'
  assert_line "$inspection" "DOC${TAB}gateway.networking.k8s.io/v1${TAB}ListenerSet${TAB}${RELEASE_NAMESPACE}${TAB}harness-listeners" 'ListenerSet namespace'
  assert_line "$inspection" "LISTENER_PARENT${TAB}harness-listeners${TAB}gateway.networking.k8s.io${TAB}Gateway${TAB}apps-gateway${TAB}envoy-gateway-apps" 'ListenerSet parent'
  assert_line "$inspection" "LISTENER${TAB}harness-listeners${TAB}harness-https${TAB}harness.example.invalid${TAB}443${TAB}HTTPS${TAB}harness-contract-tls" 'Harness listener'
  assert_line "$inspection" "LISTENER${TAB}harness-listeners${TAB}looker-https${TAB}looker.example.invalid${TAB}443${TAB}HTTPS${TAB}looker-contract-tls" 'Looker listener'
  assert_equal 2 "$(record_count "$inspection" LISTENER)" 'Listener count'
  assert_equal 1 "$(resource_count "$inspection" HTTPRoute looker)" 'Looker HTTPRoute count'
  assert_line "$inspection" "ROUTE_PARENT${TAB}harness-ui${TAB}${RELEASE_NAMESPACE}${TAB}gateway.networking.k8s.io${TAB}ListenerSet${TAB}harness-listeners${TAB}${RELEASE_NAMESPACE}${TAB}harness-https" 'Harness UI route parent'
  assert_line "$inspection" "ROUTE_PARENT${TAB}looker${TAB}${RELEASE_NAMESPACE}${TAB}gateway.networking.k8s.io${TAB}ListenerSet${TAB}harness-listeners${TAB}${RELEASE_NAMESPACE}${TAB}looker-https" 'Looker route parent'
  assert_line "$inspection" "ROUTE_HOST${TAB}looker${TAB}looker.example.invalid" 'Looker route hostname'
  assert_line "$inspection" "DOC${TAB}gateway.networking.k8s.io/v1${TAB}ReferenceGrant${TAB}${RELEASE_NAMESPACE}${TAB}allow-apps-gateway-tls" 'ReferenceGrant namespace'
  assert_line "$inspection" "GRANT_FROM${TAB}allow-apps-gateway-tls${TAB}gateway.networking.k8s.io${TAB}Gateway${TAB}envoy-gateway-apps" 'ReferenceGrant source'
  assert_line "$inspection" "GRANT_TO${TAB}allow-apps-gateway-tls${TAB}${TAB}Secret${TAB}harness-contract-tls" 'Harness TLS grant'
  assert_line "$inspection" "GRANT_TO${TAB}allow-apps-gateway-tls${TAB}${TAB}Secret${TAB}looker-contract-tls" 'Looker TLS grant'
  assert_equal 0 "$(resource_count "$inspection" CiliumNetworkPolicy)" 'default CiliumNetworkPolicy count'
}

check_overlay_without_looker() {
  local manifest="$TEST_TMP/overlay-no-looker.yaml"
  local inspection="$TEST_TMP/overlay-no-looker.tsv"
  render_overlay false false "$manifest"
  inspect_manifest "$manifest" "$inspection"

  assert_equal 1 "$(record_count "$inspection" LISTENER)" 'Looker-disabled listener count'
  assert_line "$inspection" "LISTENER${TAB}harness-listeners${TAB}harness-https${TAB}harness.example.invalid${TAB}443${TAB}HTTPS${TAB}harness-contract-tls" 'Looker-disabled Harness listener'
  assert_equal 0 "$(resource_count "$inspection" HTTPRoute looker)" 'Looker-disabled route count'
  assert_equal 1 "$(record_count "$inspection" GRANT_TO)" 'Looker-disabled TLS grant count'
  assert_line "$inspection" "GRANT_TO${TAB}allow-apps-gateway-tls${TAB}${TAB}Secret${TAB}harness-contract-tls" 'Looker-disabled TLS grant'
}

check_existing_service_overrides() {
  local manifest="$TEST_TMP/overlay-service-override.yaml"
  local inspection="$TEST_TMP/overlay-service-override.tsv"
  render_overlay false false "$manifest" \
    --set-string next-gen-ui.nameOverride=custom-next-gen-ui \
    --set next-gen-ui.service.port=8080
  inspect_manifest "$manifest" "$inspection"
  assert_line "$inspection" "ROUTE_BACKEND${TAB}harness-ui${TAB}harness.example.invalid${TAB}/${TAB}custom-next-gen-ui${TAB}8080" 'NextGen UI Service override'
}

check_overlay_platform_contract() {
  local stdout="$TEST_TMP/invalid-overlay.stdout"
  local stderr="$TEST_TMP/invalid-overlay.stderr"
  if helm template harness-gateway-api "$ROOT" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$VALUES_BASE_FILE" >"$stdout" 2>"$stderr"; then
    fail 'overlay without existing Platform Gateway API values must fail'
  fi
  assert_empty "$stdout" 'invalid Platform contract stdout'
  grep -Fq 'global.ingress.enabled must be true' "$stderr" || \
    fail 'invalid Platform contract must explain the first missing prerequisite'
}

check_cilium_opt_in() {
  local manifest="$TEST_TMP/overlay-cilium.yaml"
  local inspection="$TEST_TMP/overlay-cilium.tsv"
  render_overlay false true "$manifest"
  inspect_manifest "$manifest" "$inspection"
  assert_equal 1 "$(resource_count "$inspection" CiliumNetworkPolicy allow-envoy-gateway)" 'CiliumNetworkPolicy count'
  assert_line "$inspection" \
    "CILIUM${TAB}allow-envoy-gateway${TAB}{}${TAB}false${TAB}{\"k8s:gateway.envoyproxy.io/owning-gateway-name\":\"apps-gateway\",\"k8s:gateway.envoyproxy.io/owning-gateway-namespace\":\"envoy-gateway-apps\",\"k8s:io.kubernetes.pod.namespace\":\"envoy-gateway-apps\"}" \
    'Cilium policy contract'
}

write_post_renderer_fixture() {
  local output=$1
  cat >"$output" <<EOF
# GATEWAY API MIGRATION SUGGESTION: retain this comment exactly
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: native-route
  namespace: $RELEASE_NAMESPACE
spec:
  parentRefs:
    - name: harness-listeners
      namespace: $RELEASE_NAMESPACE
      sectionName: harness-https
  rules: []
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: HTTPRouteFilter
metadata:
  name: unrelated-filter
  namespace: $RELEASE_NAMESPACE
spec: {}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: untouched
  namespace: $RELEASE_NAMESPACE
data:
  exact: "yes"
EOF
}

check_post_renderer_contract() {
  local input="$TEST_TMP/post-input.yaml"
  local output="$TEST_TMP/post-output.yaml"
  local expected="$TEST_TMP/post-expected.yaml"
  local stderr="$TEST_TMP/post.stderr"
  write_post_renderer_fixture "$input"

  "$POST_RENDERER" <"$input" >"$output" 2>"$stderr"
  assert_empty "$stderr" 'post-renderer stderr'
  awk '
    { print }
    $0 == "    - name: harness-listeners" {
      print "      group: gateway.networking.k8s.io"
      print "      kind: ListenerSet"
    }
  ' "$input" >"$expected"
  cmp -s "$expected" "$output" || fail 'post-renderer must preserve every non-inserted byte'

  "$POST_RENDERER" <"$output" >"$TEST_TMP/post-second.yaml" 2>"$TEST_TMP/post-second.stderr"
  assert_empty "$TEST_TMP/post-second.stderr" 'second post-renderer stderr'
  cmp -s "$output" "$TEST_TMP/post-second.yaml" || fail 'post-renderer must be byte-idempotent'

  sed 's/kind: ListenerSet/kind: Gateway/' "$expected" >"$TEST_TMP/post-conflict.yaml"
  if "$POST_RENDERER" <"$TEST_TMP/post-conflict.yaml" >"$TEST_TMP/post-conflict.stdout" 2>"$TEST_TMP/post-conflict.stderr"; then
    fail 'conflicting parent kind must fail closed'
  fi
  assert_empty "$TEST_TMP/post-conflict.stdout" 'conflicting parent stdout'
  grep -Fq 'expected "ListenerSet"' "$TEST_TMP/post-conflict.stderr" || \
    fail 'conflicting parent error must explain the expected kind'

  sed "s/^      namespace: $RELEASE_NAMESPACE$/      namespace: another-namespace/" "$input" >"$TEST_TMP/post-cross.yaml"
  if "$POST_RENDERER" <"$TEST_TMP/post-cross.yaml" >"$TEST_TMP/post-cross.stdout" 2>"$TEST_TMP/post-cross.stderr"; then
    fail 'cross-namespace ListenerSet parent must fail closed'
  fi
  assert_empty "$TEST_TMP/post-cross.stdout" 'cross-namespace parent stdout'
  grep -Fq 'expected local namespace' "$TEST_TMP/post-cross.stderr" || \
    fail 'cross-namespace error must explain the local namespace contract'

  awk '
    $0 == "    - name: harness-listeners" {
      print "    - group: \"\" # keep this comment"
      print "      kind:"
      print "      name: harness-listeners"
      next
    }
    { print }
  ' "$input" >"$TEST_TMP/post-empty.yaml"
  "$POST_RENDERER" <"$TEST_TMP/post-empty.yaml" >"$TEST_TMP/post-empty.stdout" 2>"$TEST_TMP/post-empty.stderr"
  grep -Fq '    - group: gateway.networking.k8s.io # keep this comment' "$TEST_TMP/post-empty.stdout" || \
    fail 'empty group replacement must preserve sequence marker and comment'
  grep -Fq '      kind: ListenerSet' "$TEST_TMP/post-empty.stdout" || \
    fail 'empty kind replacement must preserve the mapping'
  inspect_manifest "$TEST_TMP/post-empty.stdout" "$TEST_TMP/post-empty.tsv"
  assert_line "$TEST_TMP/post-empty.tsv" \
    "ROUTE_PARENT${TAB}native-route${TAB}${RELEASE_NAMESPACE}${TAB}gateway.networking.k8s.io${TAB}ListenerSet${TAB}harness-listeners${TAB}${RELEASE_NAMESPACE}${TAB}harness-https" \
    'empty parent fields must remain a valid ParentReference'

  sed 's/harness-listeners/another-gateway/' "$input" >"$TEST_TMP/post-no-target.yaml"
  if "$POST_RENDERER" <"$TEST_TMP/post-no-target.yaml" >"$TEST_TMP/post-no-target.stdout" 2>"$TEST_TMP/post-no-target.stderr"; then
    fail 'zero ListenerSet targets must fail closed'
  fi
  assert_empty "$TEST_TMP/post-no-target.stdout" 'zero-target stdout'
  grep -Fq 'exactly one reference' "$TEST_TMP/post-no-target.stderr" || \
    fail 'zero-target error must explain the expected reference'

  printf 'apiVersion: [\n' >"$TEST_TMP/post-malformed.yaml"
  if "$POST_RENDERER" <"$TEST_TMP/post-malformed.yaml" >"$TEST_TMP/post-malformed.stdout" 2>"$TEST_TMP/post-malformed.stderr"; then
    fail 'invalid YAML must fail closed'
  fi
  assert_empty "$TEST_TMP/post-malformed.stdout" 'invalid YAML stdout'
  grep -Fq 'listenerset-parentref-post-renderer' "$TEST_TMP/post-malformed.stderr" || \
    fail 'invalid YAML error must identify the renderer'

  awk '
    /^---$/ { separator++; if (separator == 3) next }
    { print }
  ' "$input" >"$TEST_TMP/post-boundary.yaml"
  "$POST_RENDERER" <"$TEST_TMP/post-boundary.yaml" >"$TEST_TMP/post-boundary.stdout" 2>"$TEST_TMP/post-boundary.stderr"
  inspect_manifest "$TEST_TMP/post-boundary.stdout" "$TEST_TMP/post-boundary.tsv"
  assert_equal 3 "$(record_count "$TEST_TMP/post-boundary.tsv" DOC)" 'document-boundary repair resource count'
}

validate_native_parent_records() {
  local inspection=$1
  local route_count parent_count
  route_count=$(record_count "$inspection" ROUTE_META)
  parent_count=$(record_count "$inspection" ROUTE_PARENT)
  [[ "$route_count" -gt 0 ]] || fail 'native Harness render must contain HTTPRoutes'
  assert_equal "$route_count" "$parent_count" 'native route/parent count'
  if ! awk -F '\t' -v namespace="$RELEASE_NAMESPACE" '
    $1 == "ROUTE_META" && $4 > 16 { exit 1 }
    $1 == "ROUTE_PARENT" {
      if ($3 != namespace ||
          $4 != "gateway.networking.k8s.io" ||
          $5 != "ListenerSet" ||
          $6 != "harness-listeners" ||
          ($7 != "" && $7 != namespace) ||
          $8 != "harness-https") {
        exit 1
      }
    }
  ' "$inspection"; then
    fail 'native HTTPRoute parent or 16-rule contract is invalid'
  fi
}

check_native_parent_refs() {
  local native="$TEST_TMP/native.yaml"
  local rendered="$TEST_TMP/native-post.yaml"
  local inspection="$TEST_TMP/native.tsv"
  render_native "$native" \
    --set global.ng.enabled=true \
    --set global.cg.enabled=false \
    --set global.ngcustomdashboard.enabled=false
  "$POST_RENDERER" <"$native" >"$rendered" 2>"$TEST_TMP/native-post.stderr"
  inspect_manifest "$rendered" "$inspection"
  validate_native_parent_records "$inspection"
}

check_classic_only_not_silent() {
  local native="$TEST_TMP/classic.yaml"
  local rendered="$TEST_TMP/classic-post.yaml"
  local stderr="$TEST_TMP/classic-post.stderr"
  render_native "$native" \
    --set-string "global.gatewayAPI.parentRef.namespace=$RELEASE_NAMESPACE" \
    --set global.ng.enabled=false \
    --set global.cg.enabled=true \
    --set global.cdc.enabled=false \
    --set global.ssca.enabled=false \
    --set global.ngcustomdashboard.enabled=false

  if "$POST_RENDERER" <"$native" >"$rendered" 2>"$stderr"; then
    inspect_manifest "$rendered" "$TEST_TMP/classic.tsv"
    validate_native_parent_records "$TEST_TMP/classic.tsv"
  else
    assert_empty "$rendered" 'unsupported Classic-only render stdout'
    grep -Fq 'no HTTPRoute parentRef targets' "$stderr" || \
      fail 'Classic-only failure must specifically report missing native routes'
  fi
}

check_dynamic_ingress_parity() {
  local native="$TEST_TMP/parity-native.yaml"
  local rendered="$TEST_TMP/parity-platform.yaml"
  local overlay="$TEST_TMP/parity-overlay.yaml"
  local combined="$TEST_TMP/parity-combined.yaml"
  local platform_inspection="$TEST_TMP/parity-platform.tsv"
  local combined_inspection="$TEST_TMP/parity-combined.tsv"

  render_native "$native" \
    --set global.ingress.tls.enabled=true \
    --set-string global.ingress.tls.secretName=harness-contract-tls \
    --set-string "global.gatewayAPI.parentRef.namespace=$RELEASE_NAMESPACE" \
    --set global.ng.enabled=true \
    --set global.cg.enabled=false \
    --set global.cdc.enabled=true \
    --set global.ssca.enabled=true \
    --set global.servicediscoverymanager.enabled=true \
    --set global.ngcustomdashboard.enabled=true \
    --set-string 'looker.ingress.hosts[0]=looker.example.invalid' \
    --set-string looker.ingress.tls.secretName=looker-contract-tls
  "$POST_RENDERER" <"$native" >"$rendered" 2>"$TEST_TMP/parity-post.stderr"
  render_overlay true false "$overlay"
  awk '1' "$rendered" "$overlay" >"$combined"
  inspect_manifest "$rendered" "$platform_inspection"
  inspect_manifest "$combined" "$combined_inspection"

  local raw_filter_count parsed_filter_count
  raw_filter_count=$(awk '$0 == "kind: HTTPRouteFilter" { count++ } END { print count + 0 }' "$native")
  parsed_filter_count=$(resource_count "$platform_inspection" HTTPRouteFilter)
  assert_equal "$raw_filter_count" "$parsed_filter_count" 'HTTPRouteFilter count after boundary repair'

  awk -F '\t' '$1 == "INGRESS_BACKEND" { print $2 "\t" $3 "\t" $4 "\t" $5 }' \
    "$platform_inspection" | LC_ALL=C sort -u >"$TEST_TMP/ingress-tuples.tsv"
  awk -F '\t' '$1 == "ROUTE_BACKEND" { print $3 "\t" $4 "\t" $5 "\t" $6 }' \
    "$combined_inspection" | LC_ALL=C sort -u >"$TEST_TMP/route-tuples.tsv"
  [[ -s "$TEST_TMP/ingress-tuples.tsv" ]] || fail 'Ingress parity tuple set must not be empty'
  if ! cmp -s "$TEST_TMP/ingress-tuples.tsv" "$TEST_TMP/route-tuples.tsv"; then
    printf '    Missing route tuples (first 10):\n' >&2
    comm -23 "$TEST_TMP/ingress-tuples.tsv" "$TEST_TMP/route-tuples.tsv" | sed -n '1,10p' >&2
    printf '    Extra route tuples (first 10):\n' >&2
    comm -13 "$TEST_TMP/ingress-tuples.tsv" "$TEST_TMP/route-tuples.tsv" | sed -n '1,10p' >&2
    fail 'Ingress/HTTPRoute backend parity differs'
  fi
}

platform_digest_before=$(platform_hash)

run_check 'values expose only the minimal overlay switches' check_values_minimality
run_check 'Helm 4 post-renderer plugin contract is valid' check_helm4_plugin_contract
run_check 'overlay renders Harness and Looker listeners' check_overlay_with_looker
run_check 'overlay renders without any Looker values when Looker is disabled' check_overlay_without_looker
run_check 'overlay reuses existing NextGen Service overrides' check_existing_service_overrides
run_check 'overlay validates the existing Platform Gateway API contract' check_overlay_platform_contract
run_check 'Cilium policy is explicit opt-in and source-scoped' check_cilium_opt_in
run_check 'post-renderer is source-preserving, idempotent and fail-closed' check_post_renderer_contract
run_check 'native Harness HTTPRoutes attach to the ListenerSet' check_native_parent_refs
run_check 'Classic-only output can never succeed without native routes' check_classic_only_not_silent
run_check 'native plus special HTTPRoutes match the rendered Ingress backends' check_dynamic_ingress_parity

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
  printf '\n12 contract checks passed\n'
  exit 0
fi

printf '\n%d contract check(s) failed\n' "$failures" >&2
exit 1
