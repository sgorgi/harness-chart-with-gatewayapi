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
# with an explicitly supplied Helm values chain, discovers active Kubernetes
# API objects, and writes deterministic templates below templates/.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CHART_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/generate_gateway_api.sh <profile> [options] [-f FILE ...]

Profile:
  A name such as "ut" or "prod". It is used for the generated file name and
  for the gatewayAPI.environment guard inside that generated Helm template.

Helm values:
  -f, --values FILE         May be repeated. Files are passed to Helm in the
                            exact order supplied. Later files override earlier
                            files, matching normal Helm precedence.

Options:
      --chart-dir PATH      Umbrella chart directory. Default: repository root
      --release NAME        Helm release name. Default: $HELM_RELEASE or harness
      --namespace NAME      Harness release namespace. Default: $HELM_NAMESPACE or harness
      --output-dir PATH     Generated template directory. Default: templates
      --diagnostics-dir PATH
                            Diagnostic output directory. Default: .generated/gateway-api
      --implementation-specific MODE
                            Handling for ambiguous ImplementationSpecific paths:
                              auto   Regex when required or obvious, otherwise prefix
                              regex  Always translate as RegularExpression
                              prefix Always translate as PathPrefix unless the host
                                     is explicitly in ingress-nginx regex mode
                              fail   Reject every ImplementationSpecific path
                            Default: auto
      --check               Do not write templates. Fail and show a diff when stale.
      --strict-annotations  Fail when untranslated controller annotations exist.
  -h, --help                Show this help.

Examples:
  ./scripts/generate_gateway_api.sh ut \
    -f values-base.yaml \
    -f values-ut.yaml

  ./scripts/generate_gateway_api.sh prod \
    --values values-base.yaml \
    --values values-prod.yaml \
    --check

Run the script once per profile so each profile can use its own values chain.
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

resolve_from_invocation_dir() {
  local value="$1"
  if [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/%s\n' "$INVOCATION_DIR" "$value"
  fi
}

resolve_from_chart_dir() {
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


lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(lowercase "$1")" in
    true|yes|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

has_regex_metacharacters() {
  printf '%s' "$1" | grep -Eq '[][(){}|*+?$^]'
}

# ingress-nginx regex locations are case-insensitive and effectively prefix
# matches unless the expression itself anchors the end. Envoy uses RE2 and its
# route regex matcher evaluates the whole path, so append .* when no end anchor
# is present. No capture group is added, preserving $1, $2, ... numbering.
normalize_nginx_regex() {
  local pattern="$1"

  if [[ "$pattern" == '(?i)'* ]]; then
    pattern="${pattern:4}"
  fi
  if [[ "$pattern" != \^* ]]; then
    pattern="^${pattern}"
  fi
  pattern="(?i)${pattern}"
  if [[ "$pattern" != *\$ && "$pattern" != *'.*' && "$pattern" != *'.+' && "$pattern" != *'(.*)' && "$pattern" != *'(.+)' ]]; then
    pattern="${pattern}.*"
  fi

  printf '%s\n' "$pattern"
}

# Convert ingress-nginx capture references such as /$2 to the Envoy Gateway
# HTTPRouteFilter substitution form /\2. Reject unsupported remaining $ tokens.
nginx_rewrite_substitution() {
  local target="$1"
  local converted
  converted="$(printf '%s' "$target" | sed -E 's/\$([0-9]+)/\\\1/g')"
  [[ "$converted" != *'$'* ]] || fail \
    "Unsupported nginx rewrite-target '${target}'. Only numeric capture references such as \$1 and \$2 are supported."
  printf '%s\n' "$converted"
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

render_profile() {
  local environment="$1"
  local work_dir="$2"

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

  log "Rendering active Ingress resources for profile ${environment}:"
  if (( ${#VALUES_FILES[@]} == 0 )); then
    log "  Values files: none"
  else
    local values_file
    for values_file in "${VALUES_FILES[@]}"; do
      log "  ${values_file}"
    done
  fi

  # gatewayAPI.enabled=false has the highest precedence only for discovery. It
  # prevents previously generated templates from taking part in the source
  # render, while preserving the user's -f/--values precedence for everything
  # else in the umbrella chart.
  helm template "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$RELEASE_NAMESPACE" \
    "${HELM_VALUES_ARGS[@]}" \
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
  declare -A host_regex_mode=()
  declare -A route_keys=()

  # ingress-nginx applies regex matching to every path of a hostname when any
  # Ingress for that hostname enables use-regex or defines rewrite-target.
  # Discover that host-wide behavior before translating individual paths.
  while IFS=$'\t' read -r ingress_namespace ingress_name ingress_index; do
    local ingress_use_regex ingress_rewrite_target regex_rule_count regex_rule_index regex_hostname
    ingress_use_regex="$(
      yq eval -r ".[${ingress_index}].metadata.annotations.\"nginx.ingress.kubernetes.io/use-regex\" // \"false\"" "$ingresses_json"
    )"
    ingress_rewrite_target="$(
      yq eval -r ".[${ingress_index}].metadata.annotations.\"nginx.ingress.kubernetes.io/rewrite-target\" // \"\"" "$ingresses_json"
    )"
    regex_rule_count="$(yq eval ".[${ingress_index}].spec.rules // [] | length" "$ingresses_json")"

    if is_true "$ingress_use_regex" || [[ -n "$ingress_rewrite_target" ]]; then
      for ((regex_rule_index = 0; regex_rule_index < regex_rule_count; regex_rule_index++)); do
        regex_hostname="$(yq eval -r ".[${ingress_index}].spec.rules[${regex_rule_index}].host // \"\"" "$ingresses_json")"
        [[ -n "$regex_hostname" ]] && host_regex_mode[$regex_hostname]=true
      done
    fi
  done < "$sorted_ingress_indexes"

  while IFS=$'\t' read -r ingress_namespace ingress_name ingress_index; do
    [[ "$ingress_namespace" == "$RELEASE_NAMESPACE" ]] || fail \
      "Ingress ${ingress_namespace}/${ingress_name} is outside the Helm release namespace ${RELEASE_NAMESPACE}. Generated HTTPRoutes target .Release.Namespace."

    local annotations_json translated_annotations_json translated_annotations_length controller_annotations_json controller_annotations_length
    local ingress_use_regex ingress_rewrite_target
    annotations_json="$(yq eval -o=json -I=0 ".[${ingress_index}].metadata.annotations // {}" "$ingresses_json")"
    ingress_use_regex="$(
      yq eval -r ".[${ingress_index}].metadata.annotations.\"nginx.ingress.kubernetes.io/use-regex\" // \"false\"" "$ingresses_json"
    )"
    ingress_rewrite_target="$(
      yq eval -r ".[${ingress_index}].metadata.annotations.\"nginx.ingress.kubernetes.io/rewrite-target\" // \"\"" "$ingresses_json"
    )"
    translated_annotations_json="$(
      yq eval -o=json -I=0 \
        ".[${ingress_index}].metadata.annotations // {} | with_entries(select(.key == \"nginx.ingress.kubernetes.io/use-regex\" or .key == \"nginx.ingress.kubernetes.io/rewrite-target\"))" \
        "$ingresses_json"
    )"
    controller_annotations_json="$(
      yq eval -o=json -I=0 \
        ".[${ingress_index}].metadata.annotations // {} | with_entries(select(.key | test(\"^(nginx\\.ingress\\.kubernetes\\.io/|haproxy\\.org/|traefik\\.ingress\\.kubernetes\\.io/|alb\\.ingress\\.kubernetes\\.io/)\"))) | with_entries(select(.key != \"nginx.ingress.kubernetes.io/use-regex\" and .key != \"nginx.ingress.kubernetes.io/rewrite-target\"))" \
        "$ingresses_json"
    )"
    translated_annotations_length="$(TRANSLATED_ANNOTATIONS_JSON="$translated_annotations_json" yq eval -n 'env(TRANSLATED_ANNOTATIONS_JSON) | length')"
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
        local path_value ingress_path_type gateway_path_type gateway_path_value
        local service_name service_port_number service_port_name
        local effective_regex=false rewrite_json='{}'

        path_value="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].path // \"/\"" "$ingresses_json")"
        ingress_path_type="$(yq eval -r ".[${ingress_index}].spec.rules[${rule_index}].http.paths[${path_index}].pathType // \"\"" "$ingresses_json")"

        if [[ -n "${host_regex_mode[$hostname]:-}" ]]; then
          effective_regex=true
        fi

        case "$ingress_path_type" in
          Prefix)
            if [[ "$effective_regex" == "true" ]]; then
              gateway_path_type="RegularExpression"
            else
              gateway_path_type="PathPrefix"
            fi
            ;;
          Exact)
            if [[ "$effective_regex" == "true" ]]; then
              gateway_path_type="RegularExpression"
            else
              gateway_path_type="Exact"
            fi
            ;;
          ImplementationSpecific)
            case "$IMPLEMENTATION_SPECIFIC_MODE" in
              fail)
                fail "Ingress ${ingress_namespace}/${ingress_name} uses ImplementationSpecific for ${hostname}${path_value}. Select auto, regex or prefix with --implementation-specific."
                ;;
              regex)
                effective_regex=true
                ;;
              prefix)
                # An explicit host-wide ingress-nginx regex mode still wins,
                # because that is the behavior of the active source controller.
                ;;
              auto)
                if has_regex_metacharacters "$path_value"; then
                  effective_regex=true
                fi
                ;;
            esac

            if [[ "$effective_regex" == "true" ]]; then
              gateway_path_type="RegularExpression"
            else
              gateway_path_type="PathPrefix"
            fi
            ;;
          "")
            fail "Ingress ${ingress_namespace}/${ingress_name} has no pathType for ${hostname}${path_value}"
            ;;
          *)
            fail "Ingress ${ingress_namespace}/${ingress_name} uses unknown pathType '${ingress_path_type}' for ${hostname}${path_value}"
            ;;
        esac

        gateway_path_value="$path_value"
        if [[ "$gateway_path_type" == "RegularExpression" ]]; then
          gateway_path_value="$(normalize_nginx_regex "$path_value")"
        fi

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

        if [[ -n "$ingress_rewrite_target" ]]; then
          if [[ "$ingress_rewrite_target" =~ \$[0-9]+ ]]; then
            [[ "$gateway_path_type" == "RegularExpression" ]] || fail \
              "Ingress ${ingress_namespace}/${ingress_name} uses capture groups in rewrite-target '${ingress_rewrite_target}', but ${hostname}${path_value} is not a regex path"

            local rewrite_filter_name rewrite_substitution
            rewrite_filter_name="$(dns_name "rewrite-${ingress_name}-${hostname}-${path_index}-${path_value}")"
            rewrite_substitution="$(nginx_rewrite_substitution "$ingress_rewrite_target")"
            rewrite_json="$(
              REWRITE_FILTER_NAME="$rewrite_filter_name" \
              REWRITE_PATTERN="$gateway_path_value" \
              REWRITE_SUBSTITUTION="$rewrite_substitution" \
                yq eval -n -o=json -I=0 '{
                  "type": "Regex",
                  "filterName": strenv(REWRITE_FILTER_NAME),
                  "pattern": strenv(REWRITE_PATTERN),
                  "substitution": strenv(REWRITE_SUBSTITUTION)
                }'
            )"
          else
            [[ "$ingress_rewrite_target" != *'$'* ]] || fail \
              "Unsupported nginx rewrite-target '${ingress_rewrite_target}' on ${ingress_namespace}/${ingress_name}"
            rewrite_json="$(
              REWRITE_FULL_PATH="$ingress_rewrite_target" \
                yq eval -n -o=json -I=0 '{
                  "type": "ReplaceFullPath",
                  "replaceFullPath": strenv(REWRITE_FULL_PATH)
                }'
            )"
          fi
        fi

        PATH_VALUE="$gateway_path_value" \
        SOURCE_PATH_VALUE="$path_value" \
        SOURCE_PATH_TYPE="$ingress_path_type" \
        PATH_TYPE="$gateway_path_type" \
        SERVICE_NAME="$service_name" \
        SERVICE_PORT_NUMBER="$service_port_number" \
        REWRITE_JSON="$rewrite_json" \
          yq eval -n '
            {
              "path": strenv(PATH_VALUE),
              "pathType": strenv(PATH_TYPE),
              "sourcePath": strenv(SOURCE_PATH_VALUE),
              "sourcePathType": strenv(SOURCE_PATH_TYPE),
              "backend": {
                "serviceName": strenv(SERVICE_NAME),
                "servicePort": env(SERVICE_PORT_NUMBER)
              },
              "rewrite": env(REWRITE_JSON)
            }
          ' >> "$path_documents"
        printf '%s\n' '---' >> "$path_documents"
      done

      sed -i '$d' "$path_documents"
      local path_rules_json listener_name route_name
      path_rules_json="$(yq eval-all -o=json -I=0 '. as $item ireduce ([]; . + [$item]) | sort_by(.sourcePath | length) | reverse' "$path_documents")"
      listener_name="$(dns_name "https-${hostname}")"
      route_name="$(dns_name "${ingress_name}-${hostname}")"

      INGRESS_NAME="$ingress_name" \
      HOSTNAME="$hostname" \
      TLS_SECRET_NAME="$tls_secret_name" \
      LISTENER_NAME="$listener_name" \
      ROUTE_NAME="$route_name" \
      PATH_RULES_JSON="$path_rules_json" \
      ANNOTATIONS_JSON="$annotations_json" \
      TRANSLATED_ANNOTATIONS_JSON="$translated_annotations_json" \
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
            "translatedAnnotations": env(TRANSLATED_ANNOTATIONS_JSON),
            "controllerAnnotations": env(CONTROLLER_ANNOTATIONS_JSON)
          }
        ' >> "$route_documents"
      printf '%s\n' '---' >> "$route_documents"
      route_count=$((route_count + 1))

      if (( translated_annotations_length > 0 || controller_annotations_length > 0 )); then
        local annotation_source_key
        annotation_source_key="${ingress_name}|${hostname}"
        ANNOTATION_SOURCE_KEY="$annotation_source_key" \
        TRANSLATED_ANNOTATIONS_JSON="$translated_annotations_json" \
        CONTROLLER_ANNOTATIONS_JSON="$controller_annotations_json" \
          yq eval -n '{
            (strenv(ANNOTATION_SOURCE_KEY)): {
              "translated": env(TRANSLATED_ANNOTATIONS_JSON),
              "untranslated": env(CONTROLLER_ANNOTATIONS_JSON)
            }
          }' >> "$annotation_documents"
        printf '%s\n' '---' >> "$annotation_documents"
      fi
      controller_annotation_count=$((controller_annotation_count + controller_annotations_length))
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
    printf 'Untranslated controller-specific Ingress annotations were found for %s:\n' "$environment" >&2
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
      route_path_count="$(yq eval ".[${route_index}].paths | length" "$routes_json")"

      # Envoy Gateway regex rewrites are represented by HTTPRouteFilter
      # resources and referenced from the corresponding HTTPRoute rule.
      for ((route_path_index = 0; route_path_index < route_path_count; route_path_index++)); do
        local rewrite_type rewrite_filter_name rewrite_pattern rewrite_substitution
        rewrite_type="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.type // \"\"" "$routes_json")"
        if [[ "$rewrite_type" == "Regex" ]]; then
          rewrite_filter_name="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.filterName" "$routes_json")"
          rewrite_pattern="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.pattern" "$routes_json")"
          rewrite_substitution="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.substitution" "$routes_json")"

          cat <<EOF
---
# Translated from nginx.ingress.kubernetes.io/rewrite-target on ${source_ingress}.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: HTTPRouteFilter
metadata:
  name: $(yaml_quote "$rewrite_filter_name")
  namespace: {{ .Release.Namespace | quote }}
spec:
  urlRewrite:
    path:
      type: ReplaceRegexMatch
      replaceRegexMatch:
        pattern: $(yaml_quote "$rewrite_pattern")
        substitution: $(yaml_quote "$rewrite_substitution")
EOF
        fi
      done

      printf '%s\n' '---'
      printf '# Source Ingress: %s, host: %s\n' "$source_ingress" "$route_hostname"

      annotation_count="$(yq eval ".[${route_index}].translatedAnnotations | to_entries | length" "$routes_json")"
      for ((annotation_index = 0; annotation_index < annotation_count; annotation_index++)); do
        local annotation_key annotation_value_json
        annotation_key="$(
          yq eval -r ".[${route_index}].translatedAnnotations | to_entries | sort_by(.key) | .[${annotation_index}].key" "$routes_json"
        )"
        annotation_value_json="$(
          yq eval -o=json -I=0 ".[${route_index}].translatedAnnotations | to_entries | sort_by(.key) | .[${annotation_index}].value" "$routes_json"
        )"
        printf '# Translated Ingress annotation: %s=%s\n' "$annotation_key" "$annotation_value_json"
      done

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

      for ((route_path_index = 0; route_path_index < route_path_count; route_path_index++)); do
        local route_path_value route_path_type backend_name backend_port
        local rewrite_type rewrite_filter_name rewrite_full_path
        route_path_value="$(yq eval -r ".[${route_index}].paths[${route_path_index}].path" "$routes_json")"
        route_path_type="$(yq eval -r ".[${route_index}].paths[${route_path_index}].pathType" "$routes_json")"
        backend_name="$(yq eval -r ".[${route_index}].paths[${route_path_index}].backend.serviceName" "$routes_json")"
        backend_port="$(yq eval -r ".[${route_index}].paths[${route_path_index}].backend.servicePort" "$routes_json")"
        rewrite_type="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.type // \"\"" "$routes_json")"

        cat <<EOF
    - matches:
        - path:
            type: ${route_path_type}
            value: $(yaml_quote "$route_path_value")
EOF

        case "$rewrite_type" in
          Regex)
            rewrite_filter_name="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.filterName" "$routes_json")"
            cat <<EOF
      filters:
        - type: ExtensionRef
          extensionRef:
            group: gateway.envoyproxy.io
            kind: HTTPRouteFilter
            name: $(yaml_quote "$rewrite_filter_name")
EOF
            ;;
          ReplaceFullPath)
            rewrite_full_path="$(yq eval -r ".[${route_index}].paths[${route_path_index}].rewrite.replaceFullPath" "$routes_json")"
            cat <<EOF
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplaceFullPath
              replaceFullPath: $(yaml_quote "$rewrite_full_path")
EOF
            ;;
        esac

        cat <<EOF
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
    if (( ${#VALUES_FILES[@]} == 0 )); then
      printf '%s\n' '# No values files were supplied.' > "${diagnostics_environment}/values-files.txt"
    else
      printf '%s\n' "${VALUES_FILES[@]}" > "${diagnostics_environment}/values-files.txt"
    fi
  fi

  write_or_check "$generated_template" "$destination_template"

  log "${environment}: ${ingress_count} Ingress object(s), ${route_count} HTTPRoute object(s), ${host_count} HTTPS listener(s)"
  if (( controller_annotation_count > 0 )); then
    log "${environment}: ${controller_annotation_count} untranslated controller-specific annotation(s) require review"
  fi
}

[[ $# -gt 0 ]] || {
  usage
  exit 1
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

PROFILE="$1"
shift
[[ "$PROFILE" != -* ]] || fail "The first argument must be a profile name such as ut or prod"
[[ "$PROFILE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail \
  "Invalid profile '${PROFILE}'. Use a lowercase DNS-label-style value such as ut or prod."

INVOCATION_DIR="$(pwd -P)"
CHART_DIR_INPUT="$DEFAULT_CHART_DIR"
RELEASE_NAME="${HELM_RELEASE:-harness}"
RELEASE_NAMESPACE="${HELM_NAMESPACE:-harness}"
OUTPUT_DIR_INPUT="templates"
DIAGNOSTICS_DIR_INPUT=".generated/gateway-api"
IMPLEMENTATION_SPECIFIC_MODE="auto"
CHECK_ONLY=false
STRICT_ANNOTATIONS=false
STALE_OUTPUT=false
declare -a VALUES_INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--values)
      [[ $# -ge 2 ]] || fail "$1 requires a values file"
      VALUES_INPUTS+=("$2")
      shift 2
      ;;
    --values=*)
      VALUES_INPUTS+=("${1#--values=}")
      shift
      ;;
    -f?*)
      VALUES_INPUTS+=("${1#-f}")
      shift
      ;;
    --chart-dir)
      [[ $# -ge 2 ]] || fail "--chart-dir requires a value"
      CHART_DIR_INPUT="$2"
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
    --implementation-specific)
      [[ $# -ge 2 ]] || fail "--implementation-specific requires auto, regex, prefix or fail"
      IMPLEMENTATION_SPECIFIC_MODE="$2"
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

case "$IMPLEMENTATION_SPECIFIC_MODE" in
  auto|regex|prefix|fail) ;;
  *) fail "Unsupported --implementation-specific mode '${IMPLEMENTATION_SPECIFIC_MODE}'" ;;
esac

CHART_DIR="$(resolve_from_invocation_dir "$CHART_DIR_INPUT")"
[[ -d "$CHART_DIR" ]] || fail "Chart directory not found: ${CHART_DIR}"
CHART_DIR="$(cd -- "$CHART_DIR" && pwd -P)"
[[ -f "${CHART_DIR}/Chart.yaml" ]] || fail "Umbrella Chart.yaml not found: ${CHART_DIR}/Chart.yaml"

OUTPUT_DIR="$(resolve_from_chart_dir "$OUTPUT_DIR_INPUT")"
DIAGNOSTICS_DIR="$(resolve_from_chart_dir "$DIAGNOSTICS_DIR_INPUT")"

declare -a VALUES_FILES=()
declare -a HELM_VALUES_ARGS=()
for values_input in "${VALUES_INPUTS[@]}"; do
  values_file="$(resolve_from_invocation_dir "$values_input")"
  [[ -f "$values_file" ]] || fail "Values file not found: ${values_file}"
  values_file="$(cd -- "$(dirname -- "$values_file")" && pwd -P)/$(basename -- "$values_file")"
  VALUES_FILES+=("$values_file")
  HELM_VALUES_ARGS+=(--values "$values_file")
done

(( BASH_VERSINFO[0] >= 4 )) || fail "Bash 4 or newer is required. Found: ${BASH_VERSION}"

require_command helm
require_command yq
require_command sha256sum
require_command diff
require_command cmp
require_command install
require_command sed
require_command sort
require_command grep

YQ_VERSION="$(yq --version 2>/dev/null || true)"
[[ "$YQ_VERSION" == *"mikefarah/yq"* && "$YQ_VERSION" == *"version v4."* ]] || fail \
  "mikefarah/yq v4 is required. Found: ${YQ_VERSION:-unknown}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

render_profile "$PROFILE" "$WORK_DIR"

if [[ "$CHECK_ONLY" == "true" && "$STALE_OUTPUT" == "true" ]]; then
  printf '\nGenerated Gateway API template for profile %s is stale. Run the generator and commit the change.\n' "$PROFILE" >&2
  exit 1
fi
