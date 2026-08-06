#!/usr/bin/env bash

set -Eeuo pipefail

# This script intentionally uses only Helm, Bash, and mikefarah/yq v4.
# It renders Harness first, discovers stable Kubernetes routing fields, and then
# renders the temporary Gateway API chart from the generated values.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./gateway-api/render.sh <nonprod|prod>

Optional environment variables:
  HARNESS_RELEASE       Helm release name used while rendering Harness. Default: harness
  HARNESS_NAMESPACE     Namespace used while rendering Harness. Default: harness
  HARNESS_CHART         Path to the unpacked Harness chart. Default: charts/harness
  BASE_VALUES_FILE      Base Harness values file. Default: values-base.yaml
  ENV_VALUES_FILE       Environment Harness values file. Default: values-<environment>.yaml
  OUTPUT_DIR            Output directory. Default: gateway-api/generated/<environment>
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

[[ $# -eq 1 ]] || {
  usage
  exit 1
}

ENVIRONMENT="$1"
case "$ENVIRONMENT" in
  nonprod|prod) ;;
  *) fail "Unsupported environment '${ENVIRONMENT}'. Expected nonprod or prod." ;;
esac

require_command helm
require_command yq

YQ_VERSION="$(yq --version 2>/dev/null || true)"
[[ "$YQ_VERSION" == *"mikefarah/yq"* && "$YQ_VERSION" == *"version v4."* ]] || \
  fail "mikefarah/yq v4 is required. Found: ${YQ_VERSION:-unknown}"

HARNESS_RELEASE="${HARNESS_RELEASE:-harness}"
HARNESS_NAMESPACE="${HARNESS_NAMESPACE:-harness}"
HARNESS_CHART="${HARNESS_CHART:-${REPOSITORY_ROOT}/charts/harness}"
BASE_VALUES_FILE="${BASE_VALUES_FILE:-${REPOSITORY_ROOT}/values-base.yaml}"
ENV_VALUES_FILE="${ENV_VALUES_FILE:-${REPOSITORY_ROOT}/values-${ENVIRONMENT}.yaml}"
ENV_GATEWAY_VALUES_FILE="${SCRIPT_DIR}/environments/${ENVIRONMENT}.yaml"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/generated/${ENVIRONMENT}}"

[[ -f "${HARNESS_CHART}/Chart.yaml" ]] || fail "Harness chart not found at ${HARNESS_CHART}"
[[ -f "$BASE_VALUES_FILE" ]] || fail "Base values file not found: $BASE_VALUES_FILE"
[[ -f "$ENV_VALUES_FILE" ]] || fail "Environment values file not found: $ENV_VALUES_FILE"
[[ -f "$ENV_GATEWAY_VALUES_FILE" ]] || fail "Gateway environment values file not found: $ENV_GATEWAY_VALUES_FILE"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

HARNESS_RENDERED="${OUTPUT_DIR}/harness-rendered.yaml"
DISCOVERED_VALUES="${OUTPUT_DIR}/discovered-values.yaml"
GATEWAY_RENDERED="${OUTPUT_DIR}/gateway-api.yaml"
ANNOTATIONS_REPORT="${OUTPUT_DIR}/ingress-annotations.yaml"
INGRESSES_JSON="${WORK_DIR}/ingresses.json"
SERVICES_JSON="${WORK_DIR}/services.json"
ROUTE_DOCUMENTS="${WORK_DIR}/routes.yaml"

printf 'Rendering Harness for environment %s...\n' "$ENVIRONMENT"
helm template "$HARNESS_RELEASE" "$HARNESS_CHART" \
  --namespace "$HARNESS_NAMESPACE" \
  --values "$BASE_VALUES_FILE" \
  --values "$ENV_VALUES_FILE" \
  > "$HARNESS_RENDERED"

# Store all rendered Ingresses and Services as compact arrays. The generator
# deliberately ignores Harness chart internals and reads only Kubernetes APIs.
yq eval-all -o=json -I=0 '[select(.apiVersion == "networking.k8s.io/v1" and .kind == "Ingress")]' \
  "$HARNESS_RENDERED" > "$INGRESSES_JSON"
yq eval-all -o=json -I=0 '[select(.apiVersion == "v1" and .kind == "Service")]' \
  "$HARNESS_RENDERED" > "$SERVICES_JSON"

HARNESS_NAMESPACE="$HARNESS_NAMESPACE" yq eval-all '
  [
    select(.apiVersion == "networking.k8s.io/v1" and .kind == "Ingress") |
    {
      "namespace": (.metadata.namespace // strenv(HARNESS_NAMESPACE)),
      "name": .metadata.name,
      "annotations": (.metadata.annotations // {})
    }
  ]
' "$HARNESS_RENDERED" > "$ANNOTATIONS_REPORT"

INGRESS_COUNT="$(yq eval 'length' "$INGRESSES_JSON")"
[[ "$INGRESS_COUNT" -gt 0 ]] || fail "No networking.k8s.io/v1 Ingress resources were found"

: > "$ROUTE_DOCUMENTS"
ROUTE_COUNT=0
declare -A ROUTE_KEYS=()
declare -A HOST_TLS_SECRETS=()

for ((ingress_index = 0; ingress_index < INGRESS_COUNT; ingress_index++)); do
  INGRESS_NAME="$(yq eval -r ".[${ingress_index}].metadata.name // \"\"" "$INGRESSES_JSON")"
  INGRESS_NAMESPACE="$(yq eval -r ".[${ingress_index}].metadata.namespace // \"${HARNESS_NAMESPACE}\"" "$INGRESSES_JSON")"
  RULE_COUNT="$(yq eval ".[${ingress_index}].spec.rules | length" "$INGRESSES_JSON")"

  [[ -n "$INGRESS_NAME" ]] || fail "Rendered Ingress at index ${ingress_index} has no metadata.name"
  [[ "$RULE_COUNT" -gt 0 ]] || fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} has no spec.rules"

  for ((rule_index = 0; rule_index < RULE_COUNT; rule_index++)); do
    HOSTNAME="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].host // \"\"" "$INGRESSES_JSON")"
    [[ -n "$HOSTNAME" ]] || fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} contains a rule without a host"

    TLS_SECRET_NAME="$(TLS_HOST="$HOSTNAME" yq eval -r \
      "[.[${ingress_index}].spec.tls[]? | select(.hosts[]? == strenv(TLS_HOST)) | .secretName][0] // \"\"" \
      "$INGRESSES_JSON")"
    [[ -n "$TLS_SECRET_NAME" && "$TLS_SECRET_NAME" != "null" ]] || \
      fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} has no TLS secret explicitly covering host ${HOSTNAME}"

    HOST_KEY="${INGRESS_NAMESPACE}|${HOSTNAME}"
    if [[ -n "${HOST_TLS_SECRETS[$HOST_KEY]:-}" && "${HOST_TLS_SECRETS[$HOST_KEY]}" != "$TLS_SECRET_NAME" ]]; then
      fail "Host ${HOSTNAME} is mapped to multiple TLS secrets: ${HOST_TLS_SECRETS[$HOST_KEY]} and ${TLS_SECRET_NAME}"
    fi
    HOST_TLS_SECRETS[$HOST_KEY]="$TLS_SECRET_NAME"

    ROUTE_KEY="${INGRESS_NAMESPACE}|${INGRESS_NAME}|${HOSTNAME}"
    [[ -z "${ROUTE_KEYS[$ROUTE_KEY]:-}" ]] || \
      fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} contains duplicate rules for host ${HOSTNAME}"
    ROUTE_KEYS[$ROUTE_KEY]=1

    PATH_COUNT="$(yq eval ".[${ingress_index}].spec.rules[${rule_index}].http.paths | length" "$INGRESSES_JSON")"
    [[ "$PATH_COUNT" -gt 0 ]] || fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} host ${HOSTNAME} has no HTTP paths"

    PATH_DOCUMENTS="${WORK_DIR}/paths-${ingress_index}-${rule_index}.yaml"
    : > "$PATH_DOCUMENTS"

    for ((path_index = 0; path_index < PATH_COUNT; path_index++)); do
      PATH_VALUE="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].path // \"/\"" "$INGRESSES_JSON")"
      PATH_TYPE="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].pathType // \"\"" "$INGRESSES_JSON")"
      SERVICE_NAME="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].backend.service.name // \"\"" "$INGRESSES_JSON")"
      SERVICE_PORT_NUMBER="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].backend.service.port.number // \"\"" "$INGRESSES_JSON")"
      SERVICE_PORT_NAME="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].backend.service.port.name // \"\"" "$INGRESSES_JSON")"

      case "$PATH_TYPE" in
        Prefix|Exact) ;;
        *) fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} uses unsupported pathType '${PATH_TYPE}' for ${HOSTNAME}${PATH_VALUE}" ;;
      esac

      [[ -n "$SERVICE_NAME" ]] || fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} has a path without a Service backend"

      if [[ -z "$SERVICE_PORT_NUMBER" || "$SERVICE_PORT_NUMBER" == "null" ]]; then
        [[ -n "$SERVICE_PORT_NAME" && "$SERVICE_PORT_NAME" != "null" ]] || \
          fail "Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} backend ${SERVICE_NAME} has neither a numeric nor named port"

        SERVICE_PORT_NUMBER="$(
          SERVICE_NAME_FILTER="$SERVICE_NAME" \
          SERVICE_NAMESPACE_FILTER="$INGRESS_NAMESPACE" \
          SERVICE_PORT_NAME_FILTER="$SERVICE_PORT_NAME" \
          DEFAULT_NAMESPACE="$HARNESS_NAMESPACE" \
          yq eval -r '
            [
              .[] |
              select(.metadata.name == strenv(SERVICE_NAME_FILTER)) |
              select((.metadata.namespace // strenv(DEFAULT_NAMESPACE)) == strenv(SERVICE_NAMESPACE_FILTER)) |
              .spec.ports[]? |
              select(.name == strenv(SERVICE_PORT_NAME_FILTER)) |
              .port
            ][0] // ""
          ' "$SERVICES_JSON"
        )"

        [[ -n "$SERVICE_PORT_NUMBER" && "$SERVICE_PORT_NUMBER" != "null" ]] || \
          fail "Could not resolve named port '${SERVICE_PORT_NAME}' on Service ${INGRESS_NAMESPACE}/${SERVICE_NAME}"
      fi

      PATH_VALUE="$PATH_VALUE" \
      PATH_TYPE="$PATH_TYPE" \
      SERVICE_NAME="$SERVICE_NAME" \
      SERVICE_PORT_NUMBER="$SERVICE_PORT_NUMBER" \
      yq eval -n '
        {
          "path": strenv(PATH_VALUE),
          "pathType": strenv(PATH_TYPE),
          "backend": {
            "serviceName": strenv(SERVICE_NAME),
            "servicePort": env(SERVICE_PORT_NUMBER)
          }
        }
      ' >> "$PATH_DOCUMENTS"
      printf '%s\n' '---' >> "$PATH_DOCUMENTS"
    done

    # Remove the final document separator before reducing the path documents.
    sed -i '$d' "$PATH_DOCUMENTS"
    PATH_RULES_JSON="$(yq eval-all -o=json -I=0 '. as $item ireduce ([]; . + [$item])' "$PATH_DOCUMENTS")"

    INGRESS_NAME="$INGRESS_NAME" \
    INGRESS_NAMESPACE="$INGRESS_NAMESPACE" \
    HOSTNAME="$HOSTNAME" \
    TLS_SECRET_NAME="$TLS_SECRET_NAME" \
    PATH_RULES_JSON="$PATH_RULES_JSON" \
    yq eval -n '
      {
        "source": {
          "ingressName": strenv(INGRESS_NAME)
        },
        "namespace": strenv(INGRESS_NAMESPACE),
        "hostname": strenv(HOSTNAME),
        "tls": {
          "secretName": strenv(TLS_SECRET_NAME),
          "secretNamespace": strenv(INGRESS_NAMESPACE)
        },
        "rules": env(PATH_RULES_JSON)
      }
    ' >> "$ROUTE_DOCUMENTS"
    printf '%s\n' '---' >> "$ROUTE_DOCUMENTS"
    ROUTE_COUNT=$((ROUTE_COUNT + 1))
  done
done

[[ "$ROUTE_COUNT" -gt 0 ]] || fail "No routes were generated"
sed -i '$d' "$ROUTE_DOCUMENTS"

yq eval-all '. as $item ireduce ({"gatewayTransition": {"discoveredRoutes": []}}; .gatewayTransition.discoveredRoutes += [$item])' \
  "$ROUTE_DOCUMENTS" > "$DISCOVERED_VALUES"

printf 'Rendering temporary Gateway API resources...\n'
helm template harness-gateway-transition "$SCRIPT_DIR" \
  --namespace "$HARNESS_NAMESPACE" \
  --values "$ENV_GATEWAY_VALUES_FILE" \
  --values "$DISCOVERED_VALUES" \
  > "$GATEWAY_RENDERED"

printf '\nGenerated %s route model(s).\n' "$ROUTE_COUNT"
printf 'Harness render:       %s\n' "$HARNESS_RENDERED"
printf 'Discovered values:    %s\n' "$DISCOVERED_VALUES"
printf 'Ingress annotations:  %s\n' "$ANNOTATIONS_REPORT"
printf 'Gateway API render:   %s\n' "$GATEWAY_RENDERED"
