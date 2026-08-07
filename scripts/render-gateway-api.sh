#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

usage() {
  cat <<'EOF'
Render Ingress resources from a Helm chart and convert them to Envoy Gateway API resources.

Usage:
  scripts/render-gateway-api.sh -f VALUES [-f VALUES ...] [options]

Options:
  -f, --values FILE       Helm values layer; may be repeated (required)
  -o, --output DIR        Output directory; overrides gatewayApi.outputDirectory
      --chart DIR         Umbrella chart directory (default: repository root)
      --release NAME      Helm release name; overrides deployment.releaseName
      --namespace NAME    Render namespace; overrides deployment.namespace
      --keep-rendered     Also retain the complete Helm render for diagnostics
  -h, --help              Show this help

Example:
  scripts/render-gateway-api.sh -f values-base.yaml -f values-environment.yaml
EOF
}

values_files=()
chart_dir="$repo_root"
output_dir=""
release_name=""
namespace=""
keep_rendered=false

while (($#)); do
  case "$1" in
    -f|--values)
      (($# >= 2)) || { echo "error: $1 requires a file" >&2; exit 2; }
      values_files+=("$2")
      shift 2
      ;;
    -o|--output)
      (($# >= 2)) || { echo "error: $1 requires a directory" >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --chart)
      (($# >= 2)) || { echo "error: $1 requires a directory" >&2; exit 2; }
      chart_dir="$2"
      shift 2
      ;;
    --release)
      (($# >= 2)) || { echo "error: $1 requires a name" >&2; exit 2; }
      release_name="$2"
      shift 2
      ;;
    --namespace)
      (($# >= 2)) || { echo "error: $1 requires a name" >&2; exit 2; }
      namespace="$2"
      shift 2
      ;;
    --keep-rendered)
      keep_rendered=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

((${#values_files[@]} > 0)) || {
  echo "error: provide at least one values file with -f" >&2
  usage >&2
  exit 2
}

for command_name in helm yq jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: required command not found: $command_name" >&2
    exit 1
  }
done

yq --version 2>&1 | grep -q 'mikefarah/yq' || {
  echo "error: yq must be Mike Farah yq v4 (https://github.com/mikefarah/yq)" >&2
  exit 1
}

for index in "${!values_files[@]}"; do
  value_file="${values_files[$index]}"
  if [[ "$value_file" != /* ]]; then
    value_file="$PWD/$value_file"
  fi
  [[ -f "$value_file" ]] || { echo "error: values file not found: $value_file" >&2; exit 1; }
  values_files[index]="$value_file"
done

if [[ "$chart_dir" != /* ]]; then
  chart_dir="$PWD/$chart_dir"
fi
[[ -f "$chart_dir/Chart.yaml" ]] || { echo "error: Chart.yaml not found under $chart_dir" >&2; exit 1; }

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/ingress-gateway.XXXXXX")
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

merged_values="$temporary_dir/merged-values.yaml"
# shellcheck disable=SC2016 # The dollar signs belong to the yq expression.
yq eval-all '. as $item ireduce ({}; . * $item)' "${values_files[@]}" > "$merged_values"

config_value() {
  yq --unwrapScalar "$1 // \"\"" "$merged_values"
}

if [[ -z "$release_name" ]]; then
  release_name=$(config_value '.deployment.releaseName')
fi
if [[ -z "$namespace" ]]; then
  namespace=$(config_value '.deployment.namespace')
fi
if [[ -z "$output_dir" ]]; then
  output_dir=$(config_value '.gatewayApi.outputDirectory')
fi

[[ -n "$release_name" ]] || release_name=company-harness
[[ -n "$namespace" ]] || { echo "error: deployment.namespace is required (or use --namespace)" >&2; exit 1; }
[[ -n "$output_dir" ]] || { echo "error: gatewayApi.outputDirectory is required (or use --output)" >&2; exit 1; }

for required_path in \
  '.gatewayApi.parentGateway.name' \
  '.gatewayApi.parentGateway.namespace' \
  '.gatewayApi.listenerSet.name' \
  '.gatewayApi.referenceGrant.name'; do
  [[ -n "$(config_value "$required_path")" ]] || {
    echo "error: required value is missing: ${required_path#.}" >&2
    exit 1
  }
done

provider=$(config_value '.gatewayApi.provider')
[[ "$(config_value '.gatewayApi.enabled')" == "true" ]] || {
  echo "error: gatewayApi.enabled must be true" >&2
  exit 1
}
[[ "$provider" == "envoy-gateway" ]] || {
  echo "error: this generator requires gatewayApi.provider: envoy-gateway" >&2
  exit 1
}

max_rules=$(yq --unwrapScalar '.gatewayApi.httpRoute.maxRules // 16' "$merged_values")
if [[ ! "$max_rules" =~ ^[0-9]+$ ]] || ((max_rules < 1 || max_rules > 16)); then
  echo "error: gatewayApi.httpRoute.maxRules must be between 1 and 16" >&2
  exit 1
fi

if [[ "$output_dir" != /* ]]; then
  output_dir="$repo_root/$output_dir"
fi
mkdir -p "$output_dir"

rendered_file="$temporary_dir/rendered-helm.yaml"
helm_args=(template "$release_name" "$chart_dir" --namespace "$namespace" --skip-tests)
for value_file in "${values_files[@]}"; do
  helm_args+=(-f "$value_file")
done

force_ingress=$(config_value '.gatewayApi.sourceIngress.forceEnabled')
ingress_value_path=$(config_value '.gatewayApi.sourceIngress.enabledValuePath')
if [[ "$force_ingress" == "true" ]]; then
  [[ "$ingress_value_path" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "error: gatewayApi.sourceIngress.enabledValuePath is not a valid Helm value path" >&2
    exit 1
  }
  helm_args+=(--set "$ingress_value_path=true")
fi

echo "Rendering $release_name in namespace $namespace ..."
helm "${helm_args[@]}" > "$rendered_file"

documents_json="$temporary_dir/documents.json"
values_json="$temporary_dir/values.json"
result_json="$temporary_dir/generated.json"
yq eval-all --output-format=json --indent=0 '[.]' "$rendered_file" > "$documents_json"
yq eval --output-format=json --indent=0 '.' "$merged_values" > "$values_json"

jq --null-input \
  --slurpfile documents "$documents_json" \
  --slurpfile values "$values_json" \
  --arg namespace "$namespace" '
  def enabled:
    . == true or (((. // "") | tostring | ascii_downcase) == "true");

  def dns_name:
    tostring
    | ascii_downcase
    | gsub("[^a-z0-9-]+"; "-")
    | gsub("-+"; "-")
    | sub("^-"; "")
    | sub("-$"; "")
    | if length == 0 then "generated" else . end
    | if length > 253 then .[0:253] | sub("-$"; "") else . end;

  def with_suffix($base; $suffix):
    ($base | dns_name) as $clean_base
    | ($suffix | dns_name) as $clean_suffix
    | if $suffix == "" then
        $clean_base
      elif (($clean_base | length) + ($clean_suffix | length) + 1) <= 253 then
        "\($clean_base)-\($clean_suffix)"
      else
        "\($clean_base[0:(252 - ($clean_suffix | length))] | sub("-$"; ""))-\($clean_suffix)"
      end;

  def unique_preserving_order:
    reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end);

  def gateway_duration:
    tostring | if test("^[0-9]+([.][0-9]+)?$") then . + "s" else . end;

  def regex_path:
    test("[()\\[\\]{}+*?|^$]") or contains("\\");

  def match_type($path_type; $path; $annotations):
    if $path_type == "Exact" then "Exact"
    elif $path_type == "Prefix" then "PathPrefix"
    elif (($annotations["nginx.ingress.kubernetes.io/use-regex"] // "" | tostring | ascii_downcase) == "true")
      or ($annotations | has("nginx.ingress.kubernetes.io/rewrite-target"))
      or ($path | regex_path)
    then "RegularExpression"
    else "PathPrefix"
    end;

  def envoy_substitution:
    tostring | gsub("\\$"; "\\");

  def metadata($name; $namespace; $labels; $annotations):
    {name: $name, namespace: $namespace, labels: $labels}
    + if ($annotations | length) > 0 then {annotations: $annotations} else {} end;

  def parent_ref($name; $namespace; $section):
    {
      group: "gateway.networking.k8s.io",
      kind: "ListenerSet",
      name: $name,
      namespace: $namespace,
      sectionName: $section
    };

  def allowed_routes($route_namespaces; $configured):
    ($configured.namespaces // {}) as $namespace_config
    | ($namespace_config.from // "Same") as $from
    | {
        namespaces: (
          {from: $from}
          + if $from == "Selector" then
              {
                selector: (
                  $namespace_config.selector
                  // {
                    matchExpressions: [{
                      key: "kubernetes.io/metadata.name",
                      operator: "In",
                      values: ($route_namespaces | sort)
                    }]
                  }
                )
              }
            else {} end
        ),
        kinds: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute"}]
      };

  def effective_rules($ingress):
    if (($ingress.spec.rules // []) | length) > 0 then
      $ingress.spec.rules
    elif $ingress.spec.defaultBackend != null then
      [{
        host: null,
        http: {
          paths: [{path: "/", pathType: "Prefix", backend: $ingress.spec.defaultBackend}]
        }
      }]
    else [] end;

  def resolve_service_port($backend; $route_namespace; $services):
    ($backend.service // error("Ingress backend resource references are not supported")) as $service
    | if $service.port.number != null then
        ($service.port.number | tonumber)
      elif $service.port.name != null then
        ([
          $services[]
          | select((.metadata.namespace // $route_namespace) == $route_namespace)
          | select(.metadata.name == $service.name)
          | .spec.ports[]?
          | select(.name == $service.port.name)
          | .port
        ][0] // error("cannot resolve named Service port \($route_namespace)/\($service.name):\($service.port.name)"))
        | tonumber
      else
        error("Ingress backend \($route_namespace)/\($service.name) has no port")
      end;

  ($documents[0]) as $all_documents
  | ($values[0]) as $config
  | [$all_documents[] | select(.kind == "Ingress" and ((.apiVersion // "") | startswith("networking.k8s.io/")))] as $ingresses
  | [$all_documents[] | select(.kind == "Service" and .apiVersion == "v1")] as $services
  | if ($ingresses | length) == 0 then error("the Helm render did not contain any networking.k8s.io Ingress resources") else . end
  | ($config.gatewayApi.apiVersion // "gateway.networking.k8s.io/v1") as $api_version
  | ($config.gatewayApi.envoyGateway.httpRouteFilterApiVersion // "gateway.envoyproxy.io/v1alpha1") as $filter_api_version
  | ($config.gatewayApi.listenerSet) as $listener_config
  | ($config.gatewayApi.listenerSet.name) as $listener_set_name
  | ($namespace) as $listener_set_namespace
  | ($config.gatewayApi.parentGateway.name) as $parent_gateway_name
  | ($config.gatewayApi.parentGateway.namespace) as $parent_gateway_namespace
  | ($config.gatewayApi.referenceGrant.name) as $reference_grant_name
  | (($config.gatewayApi.httpRoute.maxRules // 16) | tonumber) as $max_rules
  | (($listener_config.http.enabled // true) | enabled) as $http_enabled
  | (($listener_config.https.enabled // true) | enabled) as $https_enabled
  | ($http_enabled and $https_enabled and (($listener_config.http.redirectToHttps // true) | enabled)) as $redirect_enabled
  | if ($http_enabled or $https_enabled) then . else error("at least one HTTP or HTTPS listener must be enabled") end
  | (($config.gatewayApi.commonLabels // {}) + {"gateway-api.harness.io/generated": "true"}) as $labels
  | ($config.gatewayApi.httpRoute.annotations // {}) as $common_route_annotations
  | ([$namespace]) as $route_namespaces
  | ([
      $ingresses[]
      | effective_rules(.)[]
      | .host
    ] | unique_preserving_order | if length == 0 then [null] else . end) as $hosts
  | ([
      $ingresses[] as $ingress
      | ($ingress.spec.tls // [])[]
      | select(.secretName != null)
      | {
          name: .secretName,
          namespace: $namespace
        }
    ] | unique_by([.namespace, .name])) as $all_tls_refs
  | ([
      $hosts | to_entries[]
      | .key as $host_index
      | .value as $host
      | ([
          $ingresses[] as $ingress
          | ($ingress.spec.tls // [])[]
          | select(.secretName != null)
          | . as $tls
          | ($tls.hosts // [])[]
          | select(. == $host)
          | {
              name: $tls.secretName,
              namespace: $namespace
            }
        ] | unique_by([.namespace, .name])) as $host_tls_refs
      | if ($host_tls_refs | length) > 1 then error("hostname \($host) refers to multiple TLS Secrets") else . end
      | ($host_tls_refs[0] // if ($all_tls_refs | length) == 1 then $all_tls_refs[0] else null end) as $tls_ref
      | if $https_enabled and $tls_ref == null then error("no TLS Secret was rendered for hostname \($host // "(all hosts)")") else . end
      | {
          host: $host,
          routeNamespace: $namespace,
          httpName: ("http-\($host_index + 1)-\($host // "all-hosts")" | dns_name),
          httpsName: ("https-\($host_index + 1)-\($host // "all-hosts")" | dns_name),
          tls: $tls_ref
        }
    ]) as $host_records
  | (allowed_routes($route_namespaces; ($listener_config.allowedRoutes // {}))) as $allowed_routes
  | ([
      $host_records[] as $record
      | (if $http_enabled then
          {
            name: $record.httpName,
            port: (($listener_config.http.port // 80) | tonumber),
            protocol: "HTTP",
            allowedRoutes: $allowed_routes
          }
          + if $record.host == null or $record.host == "*" then {} else {hostname: $record.host} end
        else empty end),
        (if $https_enabled then
          {
            name: $record.httpsName,
            port: (($listener_config.https.port // 443) | tonumber),
            protocol: "HTTPS",
            tls: {
              mode: "Terminate",
              certificateRefs: [
                ({group: "", kind: "Secret", name: $record.tls.name}
                 + if $record.tls.namespace != $listener_set_namespace then {namespace: $record.tls.namespace} else {} end)
              ]
            },
            allowedRoutes: $allowed_routes
          }
          + if $record.host == null or $record.host == "*" then {} else {hostname: $record.host} end
        else empty end)
    ]) as $listeners
  | ({
      apiVersion: $api_version,
      kind: "ListenerSet",
      metadata: metadata($listener_set_name; $listener_set_namespace; $labels; {}),
      spec: {
        parentRef: {
          group: "gateway.networking.k8s.io",
          kind: "Gateway",
          name: $parent_gateway_name,
          namespace: $parent_gateway_namespace
        },
        listeners: $listeners
      }
    }) as $listener_set
  | ($all_tls_refs | sort_by(.namespace) | group_by(.namespace)) as $tls_groups
  | ([
      $tls_groups | to_entries[]
      | .value as $group
      | {
          apiVersion: $api_version,
          kind: "ReferenceGrant",
          metadata: metadata(
            (if ($tls_groups | length) > 1 then with_suffix($reference_grant_name; $group[0].namespace) else ($reference_grant_name | dns_name) end);
            $group[0].namespace;
            $labels;
            {}
          ),
          spec: {
            from: [{
              group: "gateway.networking.k8s.io",
              kind: "ListenerSet",
              namespace: $listener_set_namespace
            }],
            to: ($group | map({group: "", kind: "Secret", name: .name}) | unique_by(.name))
          }
        }
    ]) as $reference_grants
  | ([
      $host_records[]
      | select($redirect_enabled)
      | {
          apiVersion: $api_version,
          kind: "HTTPRoute",
          metadata: metadata(
            (with_suffix($listener_set_name; "\(.httpName)-redirect"));
            .routeNamespace;
            $labels;
            {}
          ),
          spec: ({
            parentRefs: [parent_ref($listener_set_name; $listener_set_namespace; .httpName)],
            rules: [{
              matches: [{path: {type: "PathPrefix", value: "/"}}],
              filters: [{
                type: "RequestRedirect",
                requestRedirect: {
                  scheme: "https",
                  statusCode: (($listener_config.http.redirectStatusCode // 301) | tonumber)
                }
              }]
            }]
          } + if .host == null or .host == "*" then {} else {hostnames: [.host]} end)
        }
    ]) as $redirect_routes
  | ([
      $ingresses[] as $ingress
      | ($ingress.metadata.name) as $ingress_name
      | ($namespace) as $ingress_namespace
      | ($ingress.metadata.annotations // {}) as $ingress_annotations
      | (effective_rules($ingress)) as $ingress_rules
      | $ingress_rules | to_entries[]
      | .key as $host_index
      | .value as $ingress_rule
      | ($ingress_rule.host) as $host
      | ($ingress_rule.http.paths // []) as $paths
      | range(0; ($paths | length); $max_rules) as $start
      | ([$start + $max_rules, ($paths | length)] | min) as $stop
      | ($paths | to_entries | .[$start:$stop]) as $path_entries
      | (
          ([
            if ($ingress_rules | length) > 1 then "host-\($host_index + 1)" else empty end,
            if ($paths | length) > $max_rules then "part-\(($start / $max_rules) + 1)" else empty end
          ] | join("-"))
        ) as $route_suffix
      | (with_suffix($ingress_name; $route_suffix)) as $route_name
      | ([ $host_records[] | select(.host == $host) ][0]) as $host_record
      | ([
          if $https_enabled then parent_ref($listener_set_name; $listener_set_namespace; $host_record.httpsName) else empty end,
          if $http_enabled and (($https_enabled | not) or ($redirect_enabled | not)) then
            parent_ref($listener_set_name; $listener_set_namespace; $host_record.httpName)
          else empty end
        ]) as $parent_refs
      | ([
          $path_entries[]
          | .key as $path_index
          | .value as $path_entry
          | ($path_entry.path // "/") as $path
          | (match_type($path_entry.pathType; $path; $ingress_annotations)) as $path_match_type
          | ($path_entry.backend.service.name // error("Ingress backend resource references are not supported")) as $service_name
          | (resolve_service_port($path_entry.backend; $ingress_namespace; $services)) as $service_port
          | ($ingress_annotations["nginx.ingress.kubernetes.io/rewrite-target"] // null) as $rewrite_target
          | (if $rewrite_target != null then with_suffix($route_name; "rule-\($path_index + 1)-rewrite") else null end) as $filter_name
          | ({
              matches: [{path: {type: $path_match_type, value: $path}}]
            }
            + if $filter_name != null then {
                filters: [{
                  type: "ExtensionRef",
                  extensionRef: {
                    group: "gateway.envoyproxy.io",
                    kind: "HTTPRouteFilter",
                    name: $filter_name
                  }
                }]
              } else {} end
            + {backendRefs: [{name: $service_name, port: $service_port}]}
            + if $ingress_annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] != null then {
                timeouts: {
                  backendRequest: ($ingress_annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] | gateway_duration)
                }
              } else {} end
          ) as $route_rule
          | {
              rule: $route_rule,
              filter: (
                if $filter_name == null then null
                else {
                  apiVersion: $filter_api_version,
                  kind: "HTTPRouteFilter",
                  metadata: metadata(
                    $filter_name;
                    $ingress_namespace;
                    $labels;
                    {"gateway-api.harness.io/source-ingress": $ingress_name}
                  ),
                  spec: {
                    urlRewrite: {
                      path: {
                        type: "ReplaceRegexMatch",
                        replaceRegexMatch: {
                          pattern: $path,
                          substitution: ($rewrite_target | envoy_substitution)
                        }
                      }
                    }
                  }
                } end
              )
            }
        ]) as $path_bundles
      | {
          route: {
            apiVersion: $api_version,
            kind: "HTTPRoute",
            metadata: metadata(
              $route_name;
              $ingress_namespace;
              $labels;
              (
                $common_route_annotations
                + ($ingress_annotations | with_entries(select(.key | startswith("nginx.ingress.kubernetes.io/") | not)))
                + {"gateway-api.harness.io/source-ingress": $ingress_name}
              )
            ),
            spec: (
              {
                parentRefs: $parent_refs,
                rules: [$path_bundles[].rule]
              }
              + if $host == null or $host == "*" then {} else {hostnames: [$host]} end
            )
          },
          filters: [$path_bundles[] | select(.filter != null) | .filter]
        }
    ]) as $route_bundles
  | ([
      $ingresses[] as $ingress
      | ($namespace) as $ingress_namespace
      | ($ingress.metadata.name) as $ingress_name
      | ($ingress.metadata.annotations // {})
      | keys[]
      | select(startswith("nginx.ingress.kubernetes.io/"))
      | select(. != "nginx.ingress.kubernetes.io/proxy-read-timeout")
      | select(. != "nginx.ingress.kubernetes.io/rewrite-target")
      | select(. != "nginx.ingress.kubernetes.io/use-regex")
      | "\($ingress_namespace)/\($ingress_name): annotation \(.) was not translated"
    ] | unique) as $warnings
  | ({
      spec: {
        allowedListeners: {
          namespaces: (
            if $parent_gateway_namespace == $listener_set_namespace then {from: "Same"}
            else {
              from: "Selector",
              selector: {matchLabels: {"kubernetes.io/metadata.name": $listener_set_namespace}}
            } end
          )
        }
      }
    }) as $gateway_patch
  | {
      ingresses: $ingresses,
      listenerSets: [$listener_set],
      referenceGrants: $reference_grants,
      redirects: $redirect_routes,
      routes: [$route_bundles[].route],
      filters: [$route_bundles[].filters[]],
      gatewayPatch: $gateway_patch,
      warnings: $warnings,
      context: {
        parentGateway: "\($parent_gateway_namespace)/\($parent_gateway_name)",
        listenerSet: "\($listener_set_namespace)/\($listener_set_name)",
        routeNamespaces: $route_namespaces,
        listenerCount: ($listeners | length),
        envoyGatewayVersion: ($config.gatewayApi.envoyGateway.version // "unspecified")
      }
    }
  ' > "$result_json"

jq --exit-status --arg namespace "$namespace" '
  ([.routes[] | [.metadata.namespace, .metadata.name]] | length)
    == ([.routes[] | [.metadata.namespace, .metadata.name]] | unique | length)
  and (([.filters[] | [.metadata.namespace, .metadata.name]] | length)
    == ([.filters[] | [.metadata.namespace, .metadata.name]] | unique | length))
  and all(.routes[]; (.spec.rules | length) <= 16)
  and (([.routes[].spec.rules[].filters[]? | select(.type == "ExtensionRef") | .extensionRef.name] | sort)
    == ([.filters[].metadata.name] | sort))
  and (([.ingresses[].spec.rules[]?.http.paths[]?] | length)
    == ([.routes[].spec.rules[]] | length))
  and all(
    (.listenerSets + .referenceGrants + .redirects + .routes + .filters)[];
    .metadata.namespace == $namespace
  )
' "$result_json" >/dev/null || {
  echo "error: generated resource consistency validation failed" >&2
  exit 1
}

write_yaml_documents() {
  local expression=$1
  local destination=$2
  jq --compact-output "$expression" "$result_json" \
    | yq --input-format=json --output-format=yaml --prettyPrint '.[] | split_doc' > "$destination"
  if [[ ! -s "$destination" ]]; then
    printf '%s\n' '# No resources were generated.' > "$destination"
  fi
}

write_yaml_documents '.ingresses' "$output_dir/ingresses.yaml"
write_yaml_documents '.listenerSets' "$output_dir/00-listener-set.yaml"
write_yaml_documents '.referenceGrants' "$output_dir/10-reference-grants.yaml"
write_yaml_documents '.redirects' "$output_dir/20-http-redirects.yaml"
write_yaml_documents '.routes' "$output_dir/30-http-routes.yaml"
write_yaml_documents '.filters' "$output_dir/40-http-route-filters.yaml"
write_yaml_documents '[.gatewayPatch]' "$output_dir/gateway-allowed-listeners-patch.yaml"
write_yaml_documents '(.listenerSets + .referenceGrants + .redirects + .routes + .filters)' "$output_dir/all.yaml"

ingress_count=$(jq '.ingresses | length' "$result_json")
rule_count=$(jq '[.routes[].spec.rules[]] | length' "$result_json")
listener_count=$(jq '.context.listenerCount' "$result_json")
grant_count=$(jq '.referenceGrants | length' "$result_json")
redirect_count=$(jq '.redirects | length' "$result_json")
route_count=$(jq '.routes | length' "$result_json")
filter_count=$(jq '.filters | length' "$result_json")

{
  printf '%s\n\n' 'Harness Ingress to Gateway API conversion report'
  printf 'Source render: %s\n' "$(basename "$rendered_file")"
  printf 'Ingress resources: %s\n' "$ingress_count"
  printf 'Ingress paths / generated backend rules: %s\n' "$rule_count"
  printf 'ListenerSet listeners: %s\n' "$listener_count"
  printf 'ReferenceGrants: %s\n' "$grant_count"
  printf 'HTTP redirect routes: %s\n' "$redirect_count"
  printf 'Backend HTTPRoutes: %s\n' "$route_count"
  printf 'Envoy HTTPRouteFilters: %s\n\n' "$filter_count"
  printf 'Envoy Gateway target: %s\n' "$(jq --raw-output '.context.envoyGatewayVersion' "$result_json")"
  printf 'Parent Gateway: %s\n' "$(jq --raw-output '.context.parentGateway' "$result_json")"
  printf 'ListenerSet: %s\n' "$(jq --raw-output '.context.listenerSet' "$result_json")"
  printf 'Route namespaces: %s\n\n' "$(jq --raw-output '.context.routeNamespaces | join(", ")' "$result_json")"
  printf '%s\n' 'Warnings:'
  if [[ $(jq '.warnings | length' "$result_json") -eq 0 ]]; then
    printf '%s\n' '- none'
  else
    jq --raw-output '.warnings[] | "- " + .' "$result_json"
  fi
  printf '\n%s\n' 'The Gateway patch is intentionally excluded from all.yaml; review and apply it separately.'
} > "$output_dir/report.txt"

if [[ "$keep_rendered" == true ]]; then
  cp "$rendered_file" "$output_dir/rendered-helm.yaml"
fi

echo "Generated manifests in $output_dir"
echo "Review $output_dir/report.txt before applying them."
