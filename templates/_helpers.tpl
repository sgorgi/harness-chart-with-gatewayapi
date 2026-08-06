{{/*
Return labels shared by all temporary Gateway API resources.
*/}}
{{- define "harness-gateway-transition.labels" -}}
{{- range $key, $value := .Values.gatewayTransition.commonLabels }}
{{ $key }}: {{ $value | quote }}
{{- end }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{/*
Create a stable DNS label from arbitrary text.
The short hash prevents collisions when truncation or character replacement occurs.
*/}}
{{- define "harness-gateway-transition.dnsName" -}}
{{- $raw := lower (toString .) -}}
{{- $clean := regexReplaceAll "[^a-z0-9-]+" $raw "-" | trimAll "-" -}}
{{- $prefix := trunc 50 $clean | trimSuffix "-" -}}
{{- $hash := trunc 8 (sha256sum $raw) -}}
{{- if $prefix -}}
{{- printf "%s-%s" $prefix $hash | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "route-%s" $hash -}}
{{- end -}}
{{- end }}

{{/*
Return the listener name used by both ListenerSet and HTTPRoute.
*/}}
{{- define "harness-gateway-transition.listenerName" -}}
{{- include "harness-gateway-transition.dnsName" (printf "%s-%s" .hostname .tls.secretName) -}}
{{- end }}

{{/*
Return a stable HTTPRoute name based on the source Ingress and hostname.
*/}}
{{- define "harness-gateway-transition.routeName" -}}
{{- include "harness-gateway-transition.dnsName" (printf "%s-%s" .source.ingressName .hostname) -}}
{{- end }}

{{/*
Map Kubernetes Ingress path types to Gateway API path match types.
Unsupported values fail rendering instead of silently changing routing semantics.
*/}}
{{- define "harness-gateway-transition.pathType" -}}
{{- if eq . "Prefix" -}}
PathPrefix
{{- else if eq . "Exact" -}}
Exact
{{- else -}}
{{- fail (printf "Unsupported Ingress pathType %q. Only Prefix and Exact are supported." .) -}}
{{- end -}}
{{- end }}
