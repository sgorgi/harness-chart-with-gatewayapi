#!/usr/bin/env bash

set -Eeuo pipefail

# Generate environment-specific Gateway API Helm templates from the Ingress and
# Service manifests rendered by the company-harness umbrella chart.
#
# Requirements:
#   * Linux with Bash 4 or newer
#   * Helm 3
#   * mikefarah/yq v4
#   * GNU coreutils, diffutils, grep and sed
#
# The script never reads Harness chart internals. It renders the umbrella chart
# with the normal values chain, discovers active Kubernetes API objects, and
# writes deterministic templates below templates/.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CHART_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/generate_gateway_api.sh [ut|prod|all] [options]

Environment:
  ut                         Generate the UT template only.
  prod                       Generate the production template only.
  all                        Generate both templates. This is the default.

Options:
      --chart-dir PATH       Umbrella chart directory. Default: repository root
      --release NAME         Helm release name. Default: $HELM_RELEASE or harness
      --namespace NAME       Harness release namespace. Default: $HELM_NAMESPACE or harness
      --base-values FILE     Base values file. Default: values-base.yaml
      --ut-values FILE       UT values file. Default: values-ut.yaml
      --prod-values FILE     Production values file. Default: values-prod.yaml
      --output-dir PATH      Generated template directory. Default: templates
      --diagnostics-dir PATH Diagnostic output directory. Default: .generated/gateway-api
      --check                Do not write templates. Fail and show a diff when stale.
      --strict-annotations   Fail when controller-specific Ingress annotations exist.
  -h, --help                 Show this help.

Examples:
  ./scripts/generate_gateway_api.sh all

  ./scripts/generate_gateway_api.sh ut \
    --release harness \
    --namespace harness

  ./scripts/generate_gateway_api.sh all --check --strict-annotations
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

resolve_path() {
  local value="$1"
  if [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$CHART_DIR" "$value"
  fi
}

# JSON double-quoted strings are valid YAML scalars. This function handles the
# characters that can occur in Kubernetes names, hostnames, paths and comments.
yaml_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

# Create a stable DNS label no longer than 63 characters. The hash avoids
# collisions when normalized or truncated names share the same prefix.
dns_name() {
  local source="$1"
  local normalized digest prefix max_prefix

  normalized="$(
    printf '%s' "$source" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
  )"
  [[ -n "$normalized" ]] || normalized="generated"

  digest="$(printf '%s' "$source" | sha256sum | awk '{print substr($1, 1, 8)}')"
  max_prefix=$((63 - 1 - ${#digest}))
  prefix="${normalized:0:${max_prefix}}"
  prefix="$(printf '%s' "$prefix" | sed -E 's/-+$//')"
  [[ -n "$prefix" ]] || prefix="generated"

  printf '%s-%s\n' "$prefix" "$digest"
}

is_controller_annotation_key() {
  case "$1" in
    nginx.ingress.kubernetes.io/*|haproxy.org/*|traefik.ingress.kubernetes.io/*|alb.ingress.kubernetes.io/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

write_or_check() {
  local generated_file="$1"
  local destination_file="$2"

  if [[ -f "$destination_file" ]] && cmp -s "$generated_file" "$destination_file"; then
    log "Unchanged: ${destination_file}"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    if [[ -f "$destination_file" ]]; then
      diff -u --label "$destination_file" --label "${destination_file} (generated)" \
        "$destination_file" "$generated_file" || true
    else
      diff -u --label /dev/null --label "${destination_file} (generated)" \
        /dev/null "$generated_file" || true
    fi
    STALE_OUTPUT=true
    return 0
  fi

  mkdir -p "$(dirname -- "$destination_file")"
  install -m 0644 "$generated_file" "$destination_file"
  log "Written: ${destination_file}"
}

render_environment() {
  local environment="$1"
  local environment_values="$2"
  local work_dir="$3"

  local rendered_file="${work_dir}/${environment}-umbrella-rendered.yaml"
  local ingresses_json="${work_dir}/${environment}-ingresses.json"
  local services_json="${work_dir}/${environment}-services.json"
  local sorted_ingress_indexes="${work_dir}/${environment}-ingress-indexes.tsv"
  local route_documents="${work_dir}/${environment}-routes.yaml"
  local routes_json="${work_dir}/${environment}-routes.json"
  local annotation_documents="${work_dir}/${environment}-annotations.yaml"
  local annotation_report="${work_dir}/${environment}-ingress-annotations.json"
  local generated_template="${work_dir}/generated-gateway-api-${environment}.yaml"
  local destination_template="${OUTPUT_DIR}/generated-gateway-api-${environment}.yaml"
  local diagnostics_environment="${DIAGNOSTICS_DIR}/${environment}"

  [[ -f "$BASE_VALUES" ]] || fail "Base values file not found: ${BASE_VALUES}"
  [[ -f "$environment_values" ]] || fail "Environment values file not found: ${environment_values}"

  log "Rendering active Ingress resources for ${environment}:"
  log "  ${BASE_VALUES}"
  log "  ${environment_values}"

  helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$BASE_VALUES" \
    --values "$environment_values" \
    --set gatewayAPI.enabled=false \
    > "$rendered_file"

  # The generated Gateway API templates are disabled during discovery. The
  # resulting Ingress list therefore represents only the active source model.
  yq eval-all -o=json -I=0 \
    '[select(.apiVersion == "networking.k8s.io/v1" and .kind == "Ingress")]' \
    "$rendered_file" > "$ingresses_json"

  yq eval-all -o=json -I=0 \
    '[select(.apiVersion == "v1" and .kind == "Service")]' \
    "$rendered_file" > "$services_json"

  local ingress_count
  ingress_count="$(yq eval 'length' "$ingresses_json")"
  [[ "$ingress_count" =~ ^[0-9]+$ ]] || fail "Could not determine Ingress count for ${environment}"
  (( ingress_count > 0 )) || fail "No active networking.k8s.io/v1 Ingress resources were rendered for ${environment}"

  : > "$sorted_ingress_indexes"
  local ingress_index ingress_namespace ingress_name
  for ((ingress_index = 0; ingress_index < ingress_count; ingress_index++)); do
    ingress_namespace="$(
      DEFAULT_NAMESPACE="$RELEASE_NAMESPACE" \
        yq eval -r ".[${ingress_index}].metadata.namespace // strenv(DEFAULT_NAMESPACE)" "$ingresses_json"
    )"
    ingress_name="$(yq eval -r ".[${ingress_index}].metadata.name // \"\"" "$ingresses_json")"
    [[ -n "$ingress_name" ]] || fail "Rendered Ingress at index ${ingress_index} has no metadata.name"
    printf '%s\t%s\t%s\n' "$ingress_namespace" "$ingress_name" "$ingress_index" >> "$sorted_ingress_indexes"
  done
  LC_ALL=C sort -o "$sorted_ingress_indexes" "$sorted_ingress_indexes"

  : > "$route_documents"
  : > "$annotation_documents"

  local route_count=0
  local controller_annotation_count=0
  declare -A host_tls_secrets=()
  declare -A route_keys=()

  while IFS=$'\t' read -r ingress_namespace ingress_name ingress_index; do
    [[ "$ingress_namespace" == "$RELEASE_NAMESPACE" ]] || fail \
      "Ingress ${ingress_namespace}/${ingress_name} is outside the Helm release namespace ${RELEASE_NAMESPACE}. Generated HTTPRoutes target .Release.Namespace."

    local annotations_json controller_annotations_json controller_annotations_length
    annotations_json="$(yq eval -o=json -I=0 ".[${ingress_index}].metadata.annotations // {}" "$ingresses_json")"
    controller_annotations_json="$(
      yq eval -o=json -I=0 \
        ".[${ingress_index}].metadata.annotations // {} | with_entries(select(.key | test(\"^(nginx\\.ingress\\.kubernetes\\.io/|haproxy\\.org/|traefik\\.ingress\\.kubernetes\\.io/|alb\\.ingress\\.kubernetes\\.io/)\")))" \
        "$ingresses_json"
    )"
    controller_annotations_length="$(CONTROLLER_ANNOTATIONS_JSON="$controller_annotations_json" yq eval -n 'env(CONTROLLER_ANNOTATIONS_JSON) | length')"

    local rule_count rule_index
    rule_count="$(yq eval ".[${ingress_index}].spec.rules // [] | length" "$ingresses_json")"
    (( rule_count > 0 )) || fail "Ingress ${ingress_namespace}/${ingress_name} has no spec.rules"

    for ((rule_index = 0; rule_index < rule_count; rule_index++)); do
      local hostname route_key tls_secret_name
      hostname="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].host // \"\"" "$ingresses_json")"
      [[ -n "$hostname" ]] || fail "Ingress ${ingress_namespace}/${ingress_name} contains a rule without a hostname"

      route_key="${ingress_namespace}|${ingress_name}|${hostname}"
      [[ -z "${route_keys[$route_key]:-}" ]] || fail \
        "Ingress ${ingress_namespace}/${ingress_name} contains duplicate rules for host ${hostname}"
      route_keys[$route_key]=1

      local -a tls_secrets=()
      mapfile -t tls_secrets < <(
        TLS_HOST="$hostname" \
          yq eval -r ".[${ingress_index}].spec.tls[]? | select(.hosts[]? == strenv(TLS_HOST)) | .secretName // \"\"" "$ingresses_json" |
          sed '/^$/d; /^null$/d' |
          LC_ALL=C sort -u
      )
      (( ${#tls_secrets[@]} > 0 )) || fail \
        "Ingress ${ingress_namespace}/${ingress_name} has no TLS Secret explicitly covering host ${hostname}"
      (( ${#tls_secrets[@]} == 1 )) || fail \
        "Ingress ${ingress_namespace}/${ingress_name} maps host ${hostname} to multiple TLS Secrets: ${tls_secrets[*]}"
      tls_secret_name="${tls_secrets[0]}"

      if [[ -n "${host_tls_secrets[$hostname]:-}" && "${host_tls_secrets[$hostname]}" != "$tls_secret_name" ]]; then
        fail "Host ${hostname} is mapped to multiple TLS Secrets: ${host_tls_secrets[$hostname]} and ${tls_secret_name}"
      fi
      host_tls_secrets[$hostname]="$tls_secret_name"

      local path_count path_index path_documents
      path_count="$(yq eval ".[${ingress_index}].spec.rules[${rule_index}].http.paths // [] | length" "$ingresses_json")"
      (( path_count > 0 )) || fail "Ingress ${ingress_namespace}/${ingress_name} host ${hostname} has no HTTP paths"

      path_documents="${work_dir}/${environment}-paths-${ingress_index}-${rule_index}.yaml"
      : > "$path_documents"

      for ((path_index = 0; path_index < path_count; path_index++)); do
        local path_value ingress_path_type gateway_path_type
        local service_name service_port_number service_port_name

        path_value="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].path // \"/\"" "$ingresses_json")"
        ingress_path_type="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].pathType // \"\"" "$ingresses_json")"

        case "$ingress_path_type" in
          Prefix) gateway_path_type="PathPrefix" ;;
          Exact) gateway_path_type="Exact" ;;
          *)
            fail "Ingress ${ingress_namespace}/${ingress_name} uses unsupported pathType '${ingress_path_type}' for ${hostname}${path_value}"
            ;;
        esac

        service_name="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].backend.service.name // \"\"" "$ingresses_json")"
        [[ -n "$service_name" ]] || fail \
          "Ingress ${ingress_namespace}/${ingress_name} host ${hostname} path ${path_value} does not use a Service backend"

        service_port_number="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].backend.service.port.number // \"\"" "$ingresses_json")"
        service_port_name="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].backend.service.port.name // \"\"" "$ingresses_json")"

        if [[ -z "$service_port_number" || "$service_port_number" == "null" ]]; then
          [[ -n "$service_port_name" && "$service_port_name" != "null" ]] || fail \
            "Ingress ${ingress_namespace}/${ingress_name} backend ${service_name} has neither a numeric nor named Service port"

          local -a resolved_ports=()
          mapfile -t resolved_ports < <(
            SERVICE_NAME_FILTER="$service_name" \
            SERVICE_NAMESPACE_FILTER="$ingress_namespace" \
            SERVICE_PORT_NAME_FILTER="$service_port_name" \
            DEFAULT_NAMESPACE="$RELEASE_NAMESPACE" \
              yq eval -r '
                [
                  .[] |
                  select((.metadata.namespace // strenv(DEFAULT_NAMESPACE)) == strenv(SERVICE_NAMESPACE_FILTER)) |
                  select(.metadata.name == strenv(SERVICE_NAME_FILTER)) |
                  .spec.ports[]? |
                  select(.name == strenv(SERVICE_PORT_NAME_FILTER)) |
                  .port
                ] | unique | .[]
              ' "$services_json" |
              sed '/^$/d; /^null$/d' |
              LC_ALL=C sort -u
          )

          (( ${#resolved_ports[@]} == 1 )) || fail \
            "Could not uniquely resolve named port '${service_port_name}' on Service ${ingress_namespace}/${service_name}"
          service_port_number="${resolved_ports[0]}"
        fi

        [[ "$service_port_number" =~ ^[0-9]+$ ]] || fail \
          "Resolved Service port is not numeric for ${ingress_namespace}/${service_name}: ${service_port_number}"

        PATH_VALUE="$path_value" \
        PATH_TYPE="$gateway_path_type" \
        SERVICE_NAME="$service_name" \
        SERVICE_PORT_NUMBER="$service_port_number" \
          yq eval -n '
            {
              "path": strenv(PATH_VALUE),
              "pathType": strenv(PATH_TYPE),
              "backend": {
                "serviceName": strenv(SERVICE_NAME),
                "servicePort": env(SERVICE_PORT_NUMBER)
              }
            }
          ' >> "$path_documents"
        printf '%s\n' '---' >> "$path_documents"
      done

      sed -i '$d' "$path_documents"
      local path_rules_json listener_name route_name
      path_rules_json="$(yq eval-all -o=json -I=0 '. as $item ireduce ([]; . + [$item])' "$path_documents")"
      listener_name="$(dns_name "https-${hostname}")"
      route_name="$(dns_name "${ingress_name}-${hostname}")"

      INGRESS_NAME="$ingress_name" \
      HOSTNAME="$hostname" \
      TLS_SECRET_NAME="$tls_secret_name" \
      LISTENER_NAME="$listener_name" \
      ROUTE_NAME="$route_name" \
      PATH_RULES_JSON="$path_rules_json" \
      ANNOTATIONS_JSON="$annotations_json" \
      CONTROLLER_ANNOTATIONS_JSON="$controller_annotations_json" \
        yq eval -n '
          {
            "ingressName": strenv(INGRESS_NAME),
            "hostname": strenv(HOSTNAME),
            "tlsSecretName": strenv(TLS_SECRET_NAME),
            "listenerName": strenv(LISTENER_NAME),
            "routeName": strenv(ROUTE_NAME),
            "paths": env(PATH_RULES_JSON),
            "annotations": env(ANNOTATIONS_JSON),
            "controllerAnnotations": env(CONTROLLER_ANNOTATIONS_JSON)
          }
        ' >> "$route_documents"
      printf '%s\n' '---' >> "$route_documents"
      route_count=$((route_count + 1))

      if (( controller_annotations_length > 0 )); then
        local annotation_source_key
        annotation_source_key="${ingress_name}|${hostname}"
        ANNOTATION_SOURCE_KEY="$annotation_source_key" \
        CONTROLLER_ANNOTATIONS_JSON="$controller_annotations_json" \
          yq eval -n '{(strenv(ANNOTATION_SOURCE_KEY)): env(CONTROLLER_ANNOTATIONS_JSON)}' \
          >> "$annotation_documents"
        printf '%s\n' '---' >> "$annotation_documents"
        controller_annotation_count=$((controller_annotation_count + controller_annotations_length))
      fi
    done
  done < "$sorted_ingress_indexes"

  (( route_count > 0 )) || fail "No Gateway API routes were generated for ${environment}"
  sed -i '$d' "$route_documents"
  yq eval-all -o=json -I=0 '. as $item ireduce ([]; . + [$item])' "$route_documents" > "$routes_json"

  if [[ -s "$annotation_documents" ]]; then
    sed -i '$d' "$annotation_documents"
    yq eval-all -o=json -I=2 '. as $item ireduce ({}; . * $item)' "$annotation_documents" > "$annotation_report"
  else
    printf '{}\n' > "$annotation_report"
  fi

  if [[ "$STRICT_ANNOTATIONS" == "true" && "$controller_annotation_count" -gt 0 ]]; then
    printf 'Controller-specific Ingress annotations were found for %s:\n' "$environment" >&2
    cat "$annotation_report" >&2
    fail "Translate or remove these annotations before using --strict-annotations"
  fi

  local host_count=${#host_tls_secrets[@]}
  (( host_count > 0 )) || fail "No TLS hostnames were discovered for ${environment}"

  local sorted_hosts="${work_dir}/${environment}-hosts.txt"
  printf '%s\n' "${!host_tls_secrets[@]}" | LC_ALL=C sort > "$sorted_hosts"

  {
    cat <<EOF
{{- \$gatewayAPI := default dict .Values.gatewayAPI -}}
{{- \$gateway := default dict \$gatewayAPI.gateway -}}
{{- \$listenerSet := default dict \$gatewayAPI.listenerSet -}}
{{- \$referenceGrant := default dict \$gatewayAPI.referenceGrant -}}
{{- \$httpRedirect := default dict \$gatewayAPI.httpRedirect -}}
{{- if and (default false \$gatewayAPI.enabled) (eq (default "" \$gatewayAPI.environment) "${environment}") }}
# Code generated by scripts/generate_gateway_api.sh. DO NOT EDIT.
# Environment: ${environment}
apiVersion: gateway.networking.k8s.io/v1
kind: ListenerSet
metadata:
  name: {{ required "gatewayAPI.listenerSet.name is required" \$listenerSet.name | quote }}
  namespace: {{ required "gatewayAPI.listenerSet.namespace is required" \$listenerSet.namespace | quote }}
spec:
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: {{ required "gatewayAPI.gateway.name is required" \$gateway.name | quote }}
    namespace: {{ required "gatewayAPI.gateway.namespace is required" \$gateway.namespace | quote }}
  listeners:
EOF

    local hostname secret_name https_listener http_listener
    while IFS= read -r hostname; do
      secret_name="${host_tls_secrets[$hostname]}"
      https_listener="$(dns_name "https-${hostname}")"
      http_listener="$(dns_name "http-${hostname}")"

      printf '    - name: %s\n' "$(yaml_quote "$https_listener")"
      printf '      hostname: %s\n' "$(yaml_quote "$hostname")"
      cat <<'EOF'
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
EOF
      printf '            name: %s\n' "$(yaml_quote "$secret_name")"
      cat <<'EOF'
            namespace: {{ .Release.Namespace | quote }}
      allowedRoutes:
        namespaces:
          from: All
        kinds:
          - group: gateway.networking.k8s.io
            kind: HTTPRoute
{{- if default false $httpRedirect.enabled }}
EOF
      printf '    - name: %s\n' "$(yaml_quote "$http_listener")"
      printf '      hostname: %s\n' "$(yaml_quote "$hostname")"
      cat <<'EOF'
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
        kinds:
          - group: gateway.networking.k8s.io
            kind: HTTPRoute
{{- end }}
EOF
    done < "$sorted_hosts"

    cat <<'EOF'
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: {{ default "harness-gateway-tls" $referenceGrant.name | quote }}
  namespace: {{ .Release.Namespace | quote }}
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      namespace: {{ required "gatewayAPI.listenerSet.namespace is required" $listenerSet.namespace | quote }}
  to:
EOF

    local -A emitted_secrets=()
    while IFS= read -r hostname; do
      secret_name="${host_tls_secrets[$hostname]}"
      if [[ -z "${emitted_secrets[$secret_name]:-}" ]]; then
        emitted_secrets[$secret_name]=1
        cat <<'EOF'
    - group: ""
      kind: Secret
EOF
        printf '      name: %s\n' "$(yaml_quote "$secret_name")"
      fi
    done < "$sorted_hosts"
    local rendered_route_count route_index
    rendered_route_count="$(yq eval 'length' "$routes_json")"
    for ((route_index = 0; route_index < rendered_route_count; route_index++)); do
      local source_ingress route_hostname route_listener route_resource_name
      local route_path_count route_path_index annotation_count annotation_index

      source_ingress="$(yq eval -r ".[${route_index}].ingressName" "$routes_json")"
      route_hostname="$(yq eval -r ".[${route_index}].hostname" "$routes_json")"
      route_listener="$(yq eval -r ".[${route_index}].listenerName" "$routes_json")"
      route_resource_name="$(yq eval -r ".[${route_index}].routeName" "$routes_json")"

      printf '%s\n' '---'
      printf '# Source Ingress: %s, host: %s\n' "$source_ingress" "$route_hostname"

      annotation_count="$(yq eval ".[${route_index}].controllerAnnotations | to_entries | length" "$routes_json")"
      for ((annotation_index = 0; annotation_index < annotation_count; annotation_index++)); do
        local annotation_key annotation_value_json
        annotation_key="$(
          yq eval -r ".[${route_index}].controllerAnnotations | to_entries | sort_by(.key) | .[${annotation_index}].key" "$routes_json"
        )"
        annotation_value_json="$(
          yq eval -o=json -I=0 ".[${route_index}].controllerAnnotations | to_entries | sort_by(.key) | .[${annotation_index}].value" "$routes_json"
        )"
        printf '# Untranslated Ingress annotation: %s=%s\n' "$annotation_key" "$annotation_value_json"
      done

      cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $(yaml_quote "$route_resource_name")
  namespace: {{ .Release.Namespace | quote }}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      name: {{ required "gatewayAPI.listenerSet.name is required" \$listenerSet.name | quote }}
      namespace: {{ required "gatewayAPI.listenerSet.namespace is required" \$listenerSet.namespace | quote }}
      sectionName: $(yaml_quote "$route_listener")
  hostnames:
    - $(yaml_quote "$route_hostname")
  rules:
EOF

      route_path_count="$(yq eval ".[${route_index}].paths | length" "$routes_json")"
      for ((route_path_index = 0; route_path_index < route_path_count; route_path_index++)); do
        local route_path_value route_path_type backend_name backend_port
        route_path_value="$(yq eval -r ".[${route_index}].paths[${route_path_index}].path" "$routes_json")"
        route_path_type="$(yq eval -r ".[${route_index}].paths[${route_path_index}].pathType" "$routes_json")"
        backend_name="$(yq eval -r ".[${route_index}].paths[${route_path_index}].backend.serviceName" "$routes_json")"
        backend_port="$(yq eval -r ".[${route_index}].paths[${route_path_index}].backend.servicePort" "$routes_json")"

        cat <<EOF
    - matches:
        - path:
            type: ${route_path_type}
            value: $(yaml_quote "$route_path_value")
      backendRefs:
        - group: ""
          kind: Service
          name: $(yaml_quote "$backend_name")
          port: ${backend_port}
EOF
      done
    done

    while IFS= read -r hostname; do
      http_listener="$(dns_name "http-${hostname}")"
      cat <<EOF
{{- if default false \$httpRedirect.enabled }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $(yaml_quote "$(dns_name "redirect-${hostname}")")
  namespace: {{ .Release.Namespace | quote }}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      name: {{ required "gatewayAPI.listenerSet.name is required" \$listenerSet.name | quote }}
      namespace: {{ required "gatewayAPI.listenerSet.namespace is required" \$listenerSet.namespace | quote }}
      sectionName: $(yaml_quote "$http_listener")
  hostnames:
    - $(yaml_quote "$hostname")
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: {{ default 301 \$httpRedirect.statusCode }}
{{- end }}
EOF
    done < "$sorted_hosts"

    printf '%s\n' '{{- end }}'
  } > "$generated_template"

  if [[ "$CHECK_ONLY" != "true" ]]; then
    mkdir -p "$diagnostics_environment"
    yq eval-all 'select(.apiVersion == "networking.k8s.io/v1" and .kind == "Ingress")' \
      "$rendered_file" > "${diagnostics_environment}/active-ingresses.yaml"
    yq eval-all 'select(.apiVersion == "v1" and .kind == "Service")' \
      "$rendered_file" > "${diagnostics_environment}/active-services.yaml"
    install -m 0644 "$annotation_report" "${diagnostics_environment}/ingress-annotations.json"
  fi

  write_or_check "$generated_template" "$destination_template"

  log "${environment}: ${ingress_count} Ingress object(s), ${route_count} HTTPRoute object(s), ${host_count} HTTPS listener(s)"
  if (( controller_annotation_count > 0 )); then
    log "${environment}: ${controller_annotation_count} controller-specific annotation(s) require review"
  fi
}

ENVIRONMENT="all"
if [[ $# -gt 0 && "$1" != -* ]]; then
  ENVIRONMENT="$1"
  shift
fi

case "$ENVIRONMENT" in
  ut|prod|all) ;;
  *) fail "Unsupported environment '${ENVIRONMENT}'. Expected ut, prod or all." ;;
esac

CHART_DIR="$DEFAULT_CHART_DIR"
RELEASE_NAME="${HELM_RELEASE:-harness}"
RELEASE_NAMESPACE="${HELM_NAMESPACE:-harness}"
BASE_VALUES_INPUT="values-base.yaml"
UT_VALUES_INPUT="values-ut.yaml"
PROD_VALUES_INPUT="values-prod.yaml"
OUTPUT_DIR_INPUT="templates"
DIAGNOSTICS_DIR_INPUT=".generated/gateway-api"
CHECK_ONLY=false
STRICT_ANNOTATIONS=false
STALE_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart-dir)
      [[ $# -ge 2 ]] || fail "--chart-dir requires a value"
      CHART_DIR="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || fail "--release requires a value"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || fail "--namespace requires a value"
      RELEASE_NAMESPACE="$2"
      shift 2
      ;;
    --base-values)
      [[ $# -ge 2 ]] || fail "--base-values requires a value"
      BASE_VALUES_INPUT="$2"
      shift 2
      ;;
    --ut-values)
      [[ $# -ge 2 ]] || fail "--ut-values requires a value"
      UT_VALUES_INPUT="$2"
      shift 2
      ;;
    --prod-values)
      [[ $# -ge 2 ]] || fail "--prod-values requires a value"
      PROD_VALUES_INPUT="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR_INPUT="$2"
      shift 2
      ;;
    --diagnostics-dir)
      [[ $# -ge 2 ]] || fail "--diagnostics-dir requires a value"
      DIAGNOSTICS_DIR_INPUT="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --strict-annotations)
      STRICT_ANNOTATIONS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -d "$CHART_DIR" ]] || fail "Chart directory not found: ${CHART_DIR}"
CHART_DIR="$(cd -- "$CHART_DIR" && pwd)"
[[ -f "${CHART_DIR}/Chart.yaml" ]] || fail "Umbrella Chart.yaml not found: ${CHART_DIR}/Chart.yaml"

BASE_VALUES="$(resolve_path "$BASE_VALUES_INPUT")"
UT_VALUES="$(resolve_path "$UT_VALUES_INPUT")"
PROD_VALUES="$(resolve_path "$PROD_VALUES_INPUT")"
OUTPUT_DIR="$(resolve_path "$OUTPUT_DIR_INPUT")"
DIAGNOSTICS_DIR="$(resolve_path "$DIAGNOSTICS_DIR_INPUT")"

(( BASH_VERSINFO[0] >= 4 )) || fail "Bash 4 or newer is required. Found: ${BASH_VERSION}"

require_command helm
require_command yq
require_command sha256sum
require_command diff
require_command cmp
require_command install
require_command sed
require_command sort

YQ_VERSION="$(yq --version 2>/dev/null || true)"
[[ "$YQ_VERSION" == *"mikefarah/yq"* && "$YQ_VERSION" == *"version v4."* ]] || fail \
  "mikefarah/yq v4 is required. Found: ${YQ_VERSION:-unknown}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

case "$ENVIRONMENT" in
  ut)
    render_environment "ut" "$UT_VALUES" "$WORK_DIR"
    ;;
  prod)
    render_environment "prod" "$PROD_VALUES" "$WORK_DIR"
    ;;
  all)
    render_environment "ut" "$UT_VALUES" "$WORK_DIR"
    render_environment "prod" "$PROD_VALUES" "$WORK_DIR"
    ;;
esac

if [[ "$CHECK_ONLY" == "true" && "$STALE_OUTPUT" == "true" ]]; then
  printf '\nGenerated Gateway API templates are stale. Run the generator and commit the changes.\n' >&2
  exit 1
fi
