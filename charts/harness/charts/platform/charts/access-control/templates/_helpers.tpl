{{/*
Expand the name of the chart.
*/}}
{{- define "access-control.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "access-control.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "access-control.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "access-control.labels" -}}
helm.sh/chart: {{ include "access-control.chart" . }}
{{ include "access-control.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "access-control.selectorLabels" -}}
app.kubernetes.io/name: {{ include "access-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "access-control.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "access-control.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Manage Access-Control Secrets
USAGE:
{{- "access-control.generateSecrets" (dict "ctx" $)}}
*/}}

{{- define "access-control.generateSecrets" }}
    {{- $ := .ctx }}
    {{- $hasAtleastOneSecret := false }}
    {{- $localESOSecretCtxIdentifier := (include "harnesscommon.secrets.localESOSecretCtxIdentifier" (dict "ctx" $ )) }}
    {{- if eq (include "harnesscommon.secrets.isDefaultAppSecret" (dict "ctx" $ "variableName" "IDENTITY_SERVICE_SECRET")) "true" }}
    {{- $hasAtleastOneSecret = true }}
IDENTITY_SERVICE_SECRET: '{{ .ctx.Values.secrets.default.IDENTITY_SERVICE_SECRET | b64enc }}'
    {{- end }}
    {{- if eq (include "harnesscommon.secrets.isDefaultAppSecret" (dict "ctx" $ "variableName" "APPSEC_SERVICE_SECRET")) "true" }}
    {{- $hasAtleastOneSecret = true }}
APPSEC_SERVICE_SECRET: '{{ .ctx.Values.secrets.default.APPSEC_SERVICE_SECRET | b64enc }}'
    {{- end }}
    {{- if not $hasAtleastOneSecret }}
{}
    {{- end }}
{{- end }}
{{/*
Helper function for pullSecrets at chart level or global level.
*/}}
{{- define "access-control.pullSecrets" -}}
{{- if .Values.waitForInitContainer }}
    {{ include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.waitForInitContainer.image) "global" .Values.global ) }}
{{- else }}
    {{ include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.global.waitForInitContainer.image) "global" .Values.global ) }}
{{- end }}
{{- end -}}

{{/*
Generates comma separated list of Mongo Protocol
*/}}
{{- define "access-control.mongoProtocol" }}
    {{- $ := .ctx }}
    {{- $database := .database }}
    {{- if empty $database }}
        {{- fail "ERROR: missing input argument - database" }}
    {{- end }}
    {{- $instanceName := include "harnesscommon.dbv3.generateInstanceName" (dict "database" $database) }}
    {{- if empty $instanceName }}
        {{- fail "ERROR: invalid instanceName value" }}
    {{- end }}
    {{- $localDBCtx := get $.Values.database.mongo $instanceName }}
    {{- $globalDBCtx := $.Values.global.database.mongo }}
    {{- if and $ $localDBCtx $globalDBCtx }}
        {{- $localEnabled := dig "enabled" false $localDBCtx }}
        {{- $installed := dig "installed" true $globalDBCtx }}
        {{- $protocol := "" }}
        {{- if $localEnabled }}
            {{- $protocol = $localDBCtx.protocol }}
        {{- else if $installed }}
            {{- $protocol = "mongodb" }}
        {{- else }}
            {{- $protocol = $globalDBCtx.protocol }}
        {{- end }}
{{- printf "%s://" $protocol | quote }}
    {{- else }}
        {{- fail (printf "ERROR: invalid contexts") }}
    {{- end }}
{{- end }}

{{/*
Generates comma separated list of Mongo Host names based off environment
*/}}
{{- define "access-control.mongohosts" }}
    {{- $ := .ctx }}
    {{- $database := .database }}
    {{- if empty $database }}
        {{- fail "ERROR: missing input argument - database" }}
    {{- end }}
    {{- $instanceName := include "harnesscommon.dbv3.generateInstanceName" (dict "database" $database) }}
    {{- if empty $instanceName }}
        {{- fail "ERROR: invalid instanceName value" }}
    {{- end }}
    {{- $localDBCtx := get $.Values.database.mongo $instanceName }}
    {{- $globalDBCtx := $.Values.global.database.mongo }}
    {{- if and $ $localDBCtx $globalDBCtx }}
        {{- $localEnabled := dig "enabled" false $localDBCtx }}
        {{- $installed := dig "installed" true $globalDBCtx }}
        {{- $mongoHosts := "" }}
        {{- if $localEnabled }}
            {{- $hosts := $.Values.mongoHosts}}
            {{- $mongoHosts = (join "," $hosts ) }}
        {{- else if $installed }}
            {{- $namespace := $.Release.Namespace }}
            {{- if $.Values.global.ha }}
                {{- $mongoHosts = printf "'mongodb-replicaset-chart-0.mongodb-replicaset-chart.%s.svc,mongodb-replicaset-chart-1.mongodb-replicaset-chart.%s.svc,mongodb-replicaset-chart-2.mongodb-replicaset-chart.%s.svc:27017'" $namespace $namespace $namespace }}
            {{- else }}
                {{- $mongoHosts = printf "'mongodb-replicaset-chart-0.mongodb-replicaset-chart.%s.svc'" $namespace }}
            {{- end }}
        {{- else }}
            {{- $hosts := $.Values.mongoHosts}}
            {{- $mongoHosts = (join "," $hosts ) }}
        {{- end }}
{{- printf "%s" $mongoHosts }}
    {{- else }}
        {{- fail (printf "ERROR: invalid contexts") }}
    {{- end }}
{{- end }}

{{/* Generates Mongo Connection string
{{ include "access-control.mongoConnectionUrl" (dict "database" "foo" "context" $) }}
*/}}
{{- define "access-control.mongoConnectionUrl" }}
    {{- $ := .ctx }}
    {{- $database := .database }}
    {{- if empty $database }}
        {{- fail "ERROR: missing input argument - database" }}
    {{- end }}
    {{- $instanceName := include "harnesscommon.dbv3.generateInstanceName" (dict "database" $database) }}
    {{- if empty $instanceName }}
        {{- fail "ERROR: invalid instanceName value" }}
    {{- end }}
    {{- $localDBCtx := get $.Values.database.mongo $instanceName }}
    {{- $globalDBCtx := $.Values.global.database.mongo }}
    {{- if and $ $localDBCtx $globalDBCtx }}
        {{- $localEnabled := dig "enabled" false $localDBCtx }}
        {{- $installed := dig "installed" true $globalDBCtx }}
        {{- if $localEnabled }}
            {{- $hosts := $localDBCtx.hosts }}
            {{- $extraArgs := $localDBCtx.extraArgs }}
            {{- $database = default $database $localDBCtx.database }}
            {{- $args := (printf "/%s?%s" $database $extraArgs ) }}
            {{- $finalhost := (index $hosts  0) }}
            {{- range $host := (rest $hosts ) }}
                {{- $finalhost = printf "%s,%s" $finalhost $host }}
            {{- end }}
            {{- $connectionString := (printf "%s%s" $finalhost $args) }}
            {{- printf "%s" $connectionString }}
        {{- else if $installed }}
            {{- $namespace := $.Release.Namespace }}
            {{- if $.Values.global.ha }}
            {{- printf "'mongodb-replicaset-chart-0.mongodb-replicaset-chart.%s.svc,mongodb-replicaset-chart-1.mongodb-replicaset-chart.%s.svc,mongodb-replicaset-chart-2.mongodb-replicaset-chart.%s.svc:27017/%s?replicaSet=rs0&authSource=admin'" $namespace $namespace $namespace .database }}
            {{- else }}
                {{- printf "'mongodb-replicaset-chart-0.mongodb-replicaset-chart.%s.svc/%s?authSource=admin'" $namespace .database }}
            {{- end }}
        {{- else }}
            {{- $hosts := $globalDBCtx.hosts }}
            {{- $extraArgs := $globalDBCtx.extraArgs }}
            {{- $args := (printf "/%s?%s" $database $extraArgs ) }}
            {{- $finalhost := (index $hosts  0) }}
            {{- range $host := (rest $hosts ) }}
                {{- $finalhost = printf "%s,%s" $finalhost $host }}
            {{- end }}
            {{- $connectionString := (printf "%s%s" $finalhost $args) }}
            {{- printf "%s" $connectionString }}
        {{- end }}
    {{- else }}
        {{- fail (printf "ERROR: invalid contexts") }}
    {{- end }}
{{- end }}

{{/*
Helper function to extract port from host string in "host:port" format
Returns empty string if no valid port is found
USAGE:
{{ include "access-control.extractPortFromHost" "postgres:5432" }}
*/}}
{{- define "access-control.extractPortFromHost" -}}
{{- $host := . -}}
{{- $port := "" -}}
{{- if and $host (contains ":" $host) -}}
  {{- $hostParts := split ":" $host -}}
  {{- if and $hostParts._1 (ne $hostParts._1 "") -}}
    {{- $port = $hostParts._1 -}}
  {{- end -}}
{{- end -}}
{{- $port -}}
{{- end }}

{{/*
Generates SpiceDB PostgreSQL connection string using keyword-value format
This format handles special characters in passwords without URL encoding
USAGE:
{{ include "access-control.spicedbPostgresKeywordUri" (dict "ctx" $ "database" "spicedb") }}
*/}}
{{- define "access-control.spicedbPostgresKeywordUri" -}}
{{- $ := .ctx -}}
{{- $database := .database -}}
{{- $localDBCtx := $.Values.database.postgres -}}
{{- $globalDBCtx := $.Values.global.database.postgres -}}
{{- $host := include "harnesscommon.dbconnectionv3.postgresHost" (dict "localDBCtx" $localDBCtx "globalDBCtx" $globalDBCtx) -}}
{{- $port := "5432" -}}
{{/*
Case 1: Local config is enabled - read from chart-level postgres config
*/}}
{{- if $localDBCtx.enabled -}}
  {{- if $localDBCtx.port -}}
    {{- $port = (toString $localDBCtx.port) -}}
  {{- else if gt (len $localDBCtx.hosts) 0 -}}
    {{- $extractedPort := include "access-control.extractPortFromHost" (index $localDBCtx.hosts 0) -}}
    {{- if $extractedPort -}}
      {{- $port = $extractedPort -}}
    {{- end -}}
  {{- end -}}
{{/*
Case 2: Use global config only if global.installed is true
Priority: explicit port > port from hosts > default 5432
*/}}
{{- else if $globalDBCtx.installed -}}
  {{- if $globalDBCtx.port -}}
    {{- $port = (toString $globalDBCtx.port) -}}
  {{- else if gt (len $globalDBCtx.hosts) 0 -}}
    {{- $extractedPort := include "access-control.extractPortFromHost" (index $globalDBCtx.hosts 0) -}}
    {{- if $extractedPort -}}
      {{- $port = $extractedPort -}}
    {{- end -}}
  {{- end -}}
{{/*
Case 3: Neither local enabled nor global installed - use default port 5432
*/}}
{{- end -}}
host={{ $host }} port={{ $port }} dbname={{ $database }} sslmode=disable
{{- end }}
