{{/* Fixed integration contract for the centralized Envoy Gateway. */}}
{{- define "harness-gateway-api.gatewayName" -}}apps-gateway{{- end -}}
{{- define "harness-gateway-api.gatewayNamespace" -}}envoy-gateway-apps{{- end -}}
{{- define "harness-gateway-api.listenerSetName" -}}harness-listeners{{- end -}}
{{- define "harness-gateway-api.harnessSectionName" -}}harness-https{{- end -}}
{{- define "harness-gateway-api.lookerSectionName" -}}looker-https{{- end -}}
{{- define "harness-gateway-api.referenceGrantName" -}}allow-apps-gateway-tls{{- end -}}
{{- define "harness-gateway-api.ciliumNetworkPolicyName" -}}allow-envoy-gateway{{- end -}}

{{/*
Validate the existing Harness Gateway API contract. These are upstream
Platform values, not configuration introduced by this overlay.
*/}}
{{- define "harness-gateway-api.validatePlatformContract" -}}
{{- $allValues := fromYaml (toYaml .Values) -}}
{{- if not (dig "global" "ingress" "enabled" false $allValues) -}}
{{- fail "global.ingress.enabled must be true in the existing Harness values" -}}
{{- end -}}
{{- if not (dig "global" "ingress" "tls" "enabled" false $allValues) -}}
{{- fail "global.ingress.tls.enabled must be true in the existing Harness values" -}}
{{- end -}}
{{- $harnessHosts := dig "global" "ingress" "hosts" (list) $allValues -}}
{{- if not (kindIs "slice" $harnessHosts) -}}
{{- fail "global.ingress.hosts must be a list containing exactly one Harness FQDN" -}}
{{- end -}}
{{- if ne (len $harnessHosts) 1 -}}
{{- fail "global.ingress.hosts must contain exactly one Harness FQDN" -}}
{{- end -}}
{{- $harnessHost := first $harnessHosts -}}
{{- if or (empty $harnessHost) (contains "*" (toString $harnessHost)) -}}
{{- fail "global.ingress.hosts[0] must be a concrete Harness FQDN" -}}
{{- end -}}
{{- if not (dig "global" "gatewayAPI" "enabled" false $allValues) -}}
{{- fail "global.gatewayAPI.enabled must be true in the existing Harness values" -}}
{{- end -}}
{{- $parentRef := dig "global" "gatewayAPI" "parentRef" (dict) $allValues -}}
{{- $parentName := dig "name" "" $parentRef -}}
{{- if ne $parentName (include "harness-gateway-api.listenerSetName" .) -}}
{{- fail (printf "global.gatewayAPI.parentRef.name must be %q" (include "harness-gateway-api.listenerSetName" .)) -}}
{{- end -}}
{{- $parentSection := dig "sectionName" "" $parentRef -}}
{{- if ne $parentSection (include "harness-gateway-api.harnessSectionName" .) -}}
{{- fail (printf "global.gatewayAPI.parentRef.sectionName must be %q" (include "harness-gateway-api.harnessSectionName" .)) -}}
{{- end -}}
{{- $parentNamespace := dig "namespace" "" $parentRef -}}
{{- if and $parentNamespace (ne $parentNamespace .Release.Namespace) -}}
{{- fail (printf "global.gatewayAPI.parentRef.namespace must be empty or match the release namespace %q" .Release.Namespace) -}}
{{- end -}}
{{- $parentPort := dig "port" "" $parentRef -}}
{{- if and (not (empty $parentPort)) (ne (toString $parentPort) "443") -}}
{{- fail "global.gatewayAPI.parentRef.port must be empty or 443" -}}
{{- end -}}
{{- range $feature := list "ng" "cg" "ngcustomdashboard" -}}
{{- $featureValues := get (dig "global" (dict) $allValues) $feature | default (dict) -}}
{{- if not (kindIs "map" $featureValues) -}}
{{- fail (printf "global.%s must be a mapping with an enabled boolean" $feature) -}}
{{- end -}}
{{- if not (hasKey $featureValues "enabled") -}}
{{- fail (printf "global.%s.enabled must be explicitly set in the existing Harness values" $feature) -}}
{{- end -}}
{{- if not (kindIs "bool" (get $featureValues "enabled")) -}}
{{- fail (printf "global.%s.enabled must be a boolean" $feature) -}}
{{- end -}}
{{- end -}}
{{- if (dig "global" "ngcustomdashboard" "enabled" false $allValues) -}}
{{- $lookerHosts := dig "looker" "ingress" "hosts" (list) $allValues -}}
{{- if not (kindIs "slice" $lookerHosts) -}}
{{- fail "looker.ingress.hosts must be a list containing exactly one Looker FQDN" -}}
{{- end -}}
{{- if ne (len $lookerHosts) 1 -}}
{{- fail "looker.ingress.hosts must contain exactly one Looker FQDN" -}}
{{- end -}}
{{- $lookerHost := first $lookerHosts -}}
{{- if or (empty $lookerHost) (contains "*" (toString $lookerHost)) -}}
{{- fail "looker.ingress.hosts[0] must be a concrete Looker FQDN" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Recommended Kubernetes labels plus the existing Harness global labels. */}}
{{- define "harness-gateway-api.labels" -}}
{{- $allValues := fromYaml (toYaml .Values) -}}
{{- $labels := dict
      "app.kubernetes.io/name" .Chart.Name
      "app.kubernetes.io/instance" .Release.Name
      "app.kubernetes.io/managed-by" .Release.Service
      "app.kubernetes.io/version" .Chart.AppVersion
      "app.kubernetes.io/part-of" "harness"
      "app.kubernetes.io/component" "gateway-api"
      "helm.sh/chart" (printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_")) -}}
{{- $globalLabels := dig "global" "commonLabels" (dict) $allValues -}}
{{- $labels = mergeOverwrite $labels $globalLabels -}}
{{- toYaml $labels -}}
{{- end -}}

{{/* Reuse existing Harness global annotations without adding overlay values. */}}
{{- define "harness-gateway-api.annotations" -}}
{{- $allValues := fromYaml (toYaml .Values) -}}
{{- toYaml (dig "global" "commonAnnotations" (dict) $allValues) -}}
{{- end -}}
