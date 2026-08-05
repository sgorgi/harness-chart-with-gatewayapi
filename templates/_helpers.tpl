{{/* Fixed integration contract for the centralized Envoy Gateway. */}}
{{- define "harness-gateway-api.gatewayName" -}}apps-gateway{{- end -}}
{{- define "harness-gateway-api.gatewayNamespace" -}}envoy-gateway-apps{{- end -}}
{{- define "harness-gateway-api.listenerSetName" -}}harness-listeners{{- end -}}
{{- define "harness-gateway-api.referenceGrantName" -}}allow-apps-gateway-tls{{- end -}}
{{- define "harness-gateway-api.ciliumNetworkPolicyName" -}}allow-envoy-gateway{{- end -}}
{{- define "harness-gateway-api.inventoryPath" -}}generated/harness-gateway-inventory.json{{- end -}}

{{/* Recommended labels shared by generated and stable resources. */}}
{{- define "harness-gateway-api.labels" -}}
{{- $labels := dict
      "app.kubernetes.io/name" .Chart.Name
      "app.kubernetes.io/instance" .Release.Name
      "app.kubernetes.io/managed-by" .Release.Service
      "app.kubernetes.io/part-of" "harness"
      "app.kubernetes.io/component" "gateway-api"
      "helm.sh/chart" (printf "%s-%s" .Chart.Name (.Chart.Version | replace "+" "_")) -}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $labels "app.kubernetes.io/version" .Chart.AppVersion -}}
{{- end -}}
{{- toYaml $labels -}}
{{- end -}}

{{/*
Load and validate the versioned inventory produced from the rendered Harness
Ingress and Service manifests. Keeping this contract independent of Harness
template names makes chart upgrades visible at generation time.
*/}}
{{- define "harness-gateway-api.inventory" -}}
{{- $inventoryPath := include "harness-gateway-api.inventoryPath" . -}}
{{- $rawInventory := .Files.Get $inventoryPath -}}
{{- if empty $rawInventory -}}
{{- fail (printf "harnessGatewayOverlay.enabled is true, but %s is missing; run the Gateway API generator first" $inventoryPath) -}}
{{- end -}}
{{- $inventory := fromJson $rawInventory -}}
{{- $dnsSubdomainPattern := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?([.][a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" -}}
{{- $namespacePattern := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" -}}
{{- if not (kindIs "map" $inventory) -}}
{{- fail (printf "%s must contain a JSON object" $inventoryPath) -}}
{{- end -}}
{{- if hasKey $inventory "Error" -}}
{{- fail (printf "%s is not valid JSON: %s" $inventoryPath (get $inventory "Error")) -}}
{{- end -}}
{{- if ne (toString (get $inventory "schemaVersion")) "2" -}}
{{- fail (printf "%s has an unsupported schemaVersion; expected 2" $inventoryPath) -}}
{{- end -}}

{{- $source := get $inventory "source" -}}
{{- if not (kindIs "map" $source) -}}
{{- fail (printf "%s.source must be an object" $inventoryPath) -}}
{{- end -}}
{{- $sourceReleaseName := get $source "releaseName" -}}
{{- if or (not (kindIs "string" $sourceReleaseName)) (empty $sourceReleaseName) -}}
{{- fail (printf "%s.source.releaseName must be a non-empty string" $inventoryPath) -}}
{{- end -}}
{{- $sourceNamespace := get $source "namespace" -}}
{{- if or (not (kindIs "string" $sourceNamespace)) (ne $sourceNamespace .Release.Namespace) -}}
{{- fail (printf "%s.source.namespace must match the Helm release namespace %q" $inventoryPath .Release.Namespace) -}}
{{- end -}}
{{- if or (gt (len $sourceNamespace) 63) (not (regexMatch $namespacePattern $sourceNamespace)) -}}
{{- fail (printf "%s.source.namespace is not a valid Kubernetes namespace" $inventoryPath) -}}
{{- end -}}
{{- $sourceIngressClassName := get $source "ingressClassName" -}}
{{- if not (kindIs "string" $sourceIngressClassName) -}}
{{- fail (printf "%s.source.ingressClassName must be a string" $inventoryPath) -}}
{{- end -}}
{{- $sourceKubeVersion := get $source "kubeVersion" -}}
{{- if or (not (kindIs "string" $sourceKubeVersion)) (empty $sourceKubeVersion) -}}
{{- fail (printf "%s.source.kubeVersion must be a non-empty string" $inventoryPath) -}}
{{- end -}}
{{- $sourceHelmVersion := get $source "helmVersion" -}}
{{- if or (not (kindIs "string" $sourceHelmVersion)) (empty $sourceHelmVersion) -}}
{{- fail (printf "%s.source.helmVersion must be a non-empty string" $inventoryPath) -}}
{{- end -}}
{{- $sourceApiVersions := get $source "apiVersions" -}}
{{- if not (kindIs "slice" $sourceApiVersions) -}}
{{- fail (printf "%s.source.apiVersions must be an array" $inventoryPath) -}}
{{- end -}}
{{- $seenSourceApiVersions := dict -}}
{{- range $apiVersionIndex, $apiVersion := $sourceApiVersions -}}
{{- if or (not (kindIs "string" $apiVersion)) (empty $apiVersion) -}}
{{- fail (printf "%s.source.apiVersions[%d] must be a non-empty string" $inventoryPath $apiVersionIndex) -}}
{{- end -}}
{{- if hasKey $seenSourceApiVersions $apiVersion -}}
{{- fail (printf "%s.source.apiVersions contains duplicate %q" $inventoryPath $apiVersion) -}}
{{- end -}}
{{- $_ := set $seenSourceApiVersions $apiVersion true -}}
{{- end -}}
{{- $regexPrecedenceAcknowledged := get $source "regexPrecedenceAcknowledged" -}}
{{- if not (kindIs "bool" $regexPrecedenceAcknowledged) -}}
{{- fail (printf "%s.source.regexPrecedenceAcknowledged must be a Boolean" $inventoryPath) -}}
{{- end -}}
{{- if not (hasKey $source "routingContractSha256") -}}
{{- fail (printf "%s.source.routingContractSha256 is required" $inventoryPath) -}}
{{- end -}}
{{- $routingContractSha256 := get $source "routingContractSha256" -}}
{{- if or (not (kindIs "string" $routingContractSha256)) (not (regexMatch "^[a-f0-9]{64}$" $routingContractSha256)) -}}
{{- fail (printf "%s.source.routingContractSha256 must be a lowercase SHA-256 digest" $inventoryPath) -}}
{{- end -}}

{{- $listeners := get $inventory "listeners" -}}
{{- if not (kindIs "slice" $listeners) -}}
{{- fail (printf "%s.listeners must be an array" $inventoryPath) -}}
{{- end -}}
{{- $routes := get $inventory "routes" -}}
{{- if not (kindIs "slice" $routes) -}}
{{- fail (printf "%s.routes must be an array" $inventoryPath) -}}
{{- end -}}
{{- $httpRouteFilters := get $inventory "httpRouteFilters" -}}
{{- if not (kindIs "slice" $httpRouteFilters) -}}
{{- fail (printf "%s.httpRouteFilters must be an array" $inventoryPath) -}}
{{- end -}}
{{- $backendTrafficPolicies := get $inventory "backendTrafficPolicies" -}}
{{- if not (kindIs "slice" $backendTrafficPolicies) -}}
{{- fail (printf "%s.backendTrafficPolicies must be an array" $inventoryPath) -}}
{{- end -}}
{{- $tlsSecrets := get $inventory "tlsSecrets" -}}
{{- if not (kindIs "slice" $tlsSecrets) -}}
{{- fail (printf "%s.tlsSecrets must be an array" $inventoryPath) -}}
{{- end -}}
{{- if gt (len $listeners) 64 -}}
{{- fail (printf "%s.listeners exceeds the Gateway API limit of 64" $inventoryPath) -}}
{{- end -}}
{{- if gt (len $tlsSecrets) 16 -}}
{{- fail (printf "%s.tlsSecrets exceeds the ReferenceGrant limit of 16" $inventoryPath) -}}
{{- end -}}
{{- if and (not (empty $sourceIngressClassName)) (or (gt (len $sourceIngressClassName) 253) (not (regexMatch $dnsSubdomainPattern $sourceIngressClassName))) -}}
{{- fail (printf "%s.source.ingressClassName is invalid" $inventoryPath) -}}
{{- end -}}

{{- $tlsSecretNames := dict -}}
{{- range $secretIndex, $secretName := $tlsSecrets -}}
{{- if or (not (kindIs "string" $secretName)) (empty $secretName) (gt (len $secretName) 253) (not (regexMatch $dnsSubdomainPattern $secretName)) -}}
{{- fail (printf "%s.tlsSecrets[%d] must be a valid Kubernetes object name" $inventoryPath $secretIndex) -}}
{{- end -}}
{{- if hasKey $tlsSecretNames $secretName -}}
{{- fail (printf "%s.tlsSecrets contains duplicate name %q" $inventoryPath $secretName) -}}
{{- end -}}
{{- $_ := set $tlsSecretNames $secretName true -}}
{{- end -}}

{{- $listenersByName := dict -}}
{{- $listenerSecretNames := dict -}}
{{- range $listenerIndex, $listener := $listeners -}}
{{- if not (kindIs "map" $listener) -}}
{{- fail (printf "%s.listeners[%d] must be an object" $inventoryPath $listenerIndex) -}}
{{- end -}}
{{- $listenerName := get $listener "name" -}}
{{- if or (not (kindIs "string" $listenerName)) (empty $listenerName) (gt (len $listenerName) 253) (not (regexMatch $dnsSubdomainPattern $listenerName)) -}}
{{- fail (printf "%s.listeners[%d].name must be a valid SectionName" $inventoryPath $listenerIndex) -}}
{{- end -}}
{{- if hasKey $listenersByName $listenerName -}}
{{- fail (printf "%s.listeners contains duplicate name %q" $inventoryPath $listenerName) -}}
{{- end -}}
{{- $listenerHostname := get $listener "hostname" -}}
{{- if or (not (kindIs "string" $listenerHostname)) (empty $listenerHostname) (gt (len $listenerHostname) 253) (not (regexMatch $dnsSubdomainPattern $listenerHostname)) -}}
{{- fail (printf "%s.listeners[%d].hostname must be a concrete DNS hostname" $inventoryPath $listenerIndex) -}}
{{- end -}}
{{- $listenerTlsSecret := get $listener "tlsSecret" -}}
{{- if or (not (kindIs "string" $listenerTlsSecret)) (empty $listenerTlsSecret) (gt (len $listenerTlsSecret) 253) (not (regexMatch $dnsSubdomainPattern $listenerTlsSecret)) -}}
{{- fail (printf "%s.listeners[%d].tlsSecret must be a valid Kubernetes object name" $inventoryPath $listenerIndex) -}}
{{- end -}}
{{- if not (hasKey $tlsSecretNames $listenerTlsSecret) -}}
{{- fail (printf "%s.listeners[%d].tlsSecret %q is missing from tlsSecrets" $inventoryPath $listenerIndex $listenerTlsSecret) -}}
{{- end -}}
{{- $_ := set $listenersByName $listenerName $listener -}}
{{- $_ := set $listenerSecretNames $listenerTlsSecret true -}}
{{- end -}}
{{- range $secretName := $tlsSecrets -}}
{{- if not (hasKey $listenerSecretNames $secretName) -}}
{{- fail (printf "%s.tlsSecrets contains unreferenced Secret %q" $inventoryPath $secretName) -}}
{{- end -}}
{{- end -}}

{{- $httpRouteFiltersByName := dict -}}
{{- range $filterIndex, $httpRouteFilter := $httpRouteFilters -}}
{{- if not (kindIs "map" $httpRouteFilter) -}}
{{- fail (printf "%s.httpRouteFilters[%d] must be an object" $inventoryPath $filterIndex) -}}
{{- end -}}
{{- $filterName := get $httpRouteFilter "name" -}}
{{- if or (not (kindIs "string" $filterName)) (empty $filterName) (gt (len $filterName) 253) (not (regexMatch $dnsSubdomainPattern $filterName)) -}}
{{- fail (printf "%s.httpRouteFilters[%d].name must be a valid Kubernetes object name" $inventoryPath $filterIndex) -}}
{{- end -}}
{{- if hasKey $httpRouteFiltersByName $filterName -}}
{{- fail (printf "%s.httpRouteFilters contains duplicate name %q" $inventoryPath $filterName) -}}
{{- end -}}
{{- $pattern := get $httpRouteFilter "pattern" -}}
{{- if or (not (kindIs "string" $pattern)) (empty $pattern) (gt (len $pattern) 1024) -}}
{{- fail (printf "%s.httpRouteFilters[%d].pattern must be a non-empty string" $inventoryPath $filterIndex) -}}
{{- end -}}
{{- $_ := mustRegexMatch $pattern "" -}}
{{- $substitution := get $httpRouteFilter "substitution" -}}
{{- if not (kindIs "string" $substitution) -}}
{{- fail (printf "%s.httpRouteFilters[%d].substitution must be a string" $inventoryPath $filterIndex) -}}
{{- end -}}
{{- $_ := set $httpRouteFiltersByName $filterName true -}}
{{- end -}}

{{- $routeNames := dict -}}
{{- $routesByName := dict -}}
{{- $routesRequiringIdlePolicy := dict -}}
{{- $referencedHttpRouteFilters := dict -}}
{{- $referencedListeners := dict -}}
{{- range $routeIndex, $route := $routes -}}
{{- if not (kindIs "map" $route) -}}
{{- fail (printf "%s.routes[%d] must be an object" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- $routeName := get $route "name" -}}
{{- if or (not (kindIs "string" $routeName)) (empty $routeName) (gt (len $routeName) 253) (not (regexMatch $dnsSubdomainPattern $routeName)) -}}
{{- fail (printf "%s.routes[%d].name must be a valid Kubernetes object name" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- if hasKey $routeNames $routeName -}}
{{- fail (printf "%s.routes contains duplicate name %q" $inventoryPath $routeName) -}}
{{- end -}}
{{- $_ := set $routeNames $routeName true -}}
{{- $_ := set $routesByName $routeName $route -}}
{{- $sourceIngress := get $route "sourceIngress" -}}
{{- if or (not (kindIs "string" $sourceIngress)) (empty $sourceIngress) (gt (len $sourceIngress) 253) (not (regexMatch $dnsSubdomainPattern $sourceIngress)) -}}
{{- fail (printf "%s.routes[%d].sourceIngress must be a valid Kubernetes object name" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- $routeHostname := get $route "hostname" -}}
{{- if or (not (kindIs "string" $routeHostname)) (empty $routeHostname) (gt (len $routeHostname) 253) (not (regexMatch $dnsSubdomainPattern $routeHostname)) -}}
{{- fail (printf "%s.routes[%d].hostname must be a concrete DNS hostname" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- $sectionName := get $route "sectionName" -}}
{{- if or (not (kindIs "string" $sectionName)) (not (hasKey $listenersByName $sectionName)) -}}
{{- fail (printf "%s.routes[%d].sectionName must reference a generated listener" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- $routeListener := get $listenersByName $sectionName -}}
{{- $_ := set $referencedListeners $sectionName true -}}
{{- if ne $routeHostname (get $routeListener "hostname") -}}
{{- fail (printf "%s.routes[%d].hostname must match listener %q" $inventoryPath $routeIndex $sectionName) -}}
{{- end -}}
{{- $rules := get $route "rules" -}}
{{- if or (not (kindIs "slice" $rules)) (eq (len $rules) 0) -}}
{{- fail (printf "%s.routes[%d].rules must be a non-empty array" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- if gt (len $rules) 16 -}}
{{- fail (printf "%s.routes[%d].rules exceeds the Gateway API limit of 16" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- $timedRuleCount := 0 -}}
{{- range $ruleIndex, $rule := $rules -}}
{{- if not (kindIs "map" $rule) -}}
{{- fail (printf "%s.routes[%d].rules[%d] must be an object" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $path := get $rule "path" -}}
{{- if not (kindIs "map" $path) -}}
{{- fail (printf "%s.routes[%d].rules[%d].path must be an object" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $pathType := get $path "type" -}}
{{- if not (has $pathType (list "Exact" "PathPrefix" "RegularExpression")) -}}
{{- fail (printf "%s.routes[%d].rules[%d].path.type is unsupported" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $pathValue := get $path "value" -}}
{{- if or (not (kindIs "string" $pathValue)) (empty $pathValue) (gt (len $pathValue) 1024) -}}
{{- fail (printf "%s.routes[%d].rules[%d].path.value must be a non-empty string" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- if and (has $pathType (list "Exact" "PathPrefix")) (not (hasPrefix "/" $pathValue)) -}}
{{- fail (printf "%s.routes[%d].rules[%d].path.value must start with /" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- if eq $pathType "RegularExpression" -}}
{{- $_ := mustRegexMatch $pathValue "" -}}
{{- end -}}
{{- $backend := get $rule "backend" -}}
{{- if not (kindIs "map" $backend) -}}
{{- fail (printf "%s.routes[%d].rules[%d].backend must be an object" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $backendName := get $backend "name" -}}
{{- if or (not (kindIs "string" $backendName)) (empty $backendName) (gt (len $backendName) 253) (not (regexMatch $dnsSubdomainPattern $backendName)) -}}
{{- fail (printf "%s.routes[%d].rules[%d].backend.name must be a valid Kubernetes object name" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $backendPort := get $backend "port" -}}
{{- if not (regexMatch "^[0-9]+$" (toString $backendPort)) -}}
{{- fail (printf "%s.routes[%d].rules[%d].backend.port must be an integer" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $backendPortNumber := atoi (toString $backendPort) -}}
{{- if or (lt $backendPortNumber 1) (gt $backendPortNumber 65535) -}}
{{- fail (printf "%s.routes[%d].rules[%d].backend.port must be between 1 and 65535" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- if hasKey $rule "filters" -}}
{{- $routeFilters := get $rule "filters" -}}
{{- if not (kindIs "slice" $routeFilters) -}}
{{- fail (printf "%s.routes[%d].rules[%d].filters must be an array" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- range $routeFilterIndex, $routeFilter := $routeFilters -}}
{{- if not (kindIs "map" $routeFilter) -}}
{{- fail (printf "%s.routes[%d].rules[%d].filters[%d] must be an object" $inventoryPath $routeIndex $ruleIndex $routeFilterIndex) -}}
{{- end -}}
{{- if ne (get $routeFilter "type") "ExtensionRef" -}}
{{- fail (printf "%s.routes[%d].rules[%d].filters[%d].type must be ExtensionRef" $inventoryPath $routeIndex $ruleIndex $routeFilterIndex) -}}
{{- end -}}
{{- $extensionRef := get $routeFilter "extensionRef" -}}
{{- if not (kindIs "map" $extensionRef) -}}
{{- fail (printf "%s.routes[%d].rules[%d].filters[%d].extensionRef must be an object" $inventoryPath $routeIndex $ruleIndex $routeFilterIndex) -}}
{{- end -}}
{{- $extensionName := get $extensionRef "name" -}}
{{- if or (ne (get $extensionRef "group") "gateway.envoyproxy.io") (ne (get $extensionRef "kind") "HTTPRouteFilter") (not (kindIs "string" $extensionName)) (not (hasKey $httpRouteFiltersByName $extensionName)) -}}
{{- fail (printf "%s.routes[%d].rules[%d].filters[%d] must reference a generated Envoy HTTPRouteFilter" $inventoryPath $routeIndex $ruleIndex $routeFilterIndex) -}}
{{- end -}}
{{- $_ := set $referencedHttpRouteFilters $extensionName true -}}
{{- end -}}
{{- end -}}
{{- if hasKey $rule "timeouts" -}}
{{- $timeouts := get $rule "timeouts" -}}
{{- if not (kindIs "map" $timeouts) -}}
{{- fail (printf "%s.routes[%d].rules[%d].timeouts must be an object" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- if or (ne (len $timeouts) 2) (ne (get $timeouts "request") "0s") (ne (get $timeouts "backendRequest") "0s") -}}
{{- fail (printf "%s.routes[%d].rules[%d].timeouts must disable total request deadlines with request=0s and backendRequest=0s" $inventoryPath $routeIndex $ruleIndex) -}}
{{- end -}}
{{- $_ := set $routesRequiringIdlePolicy $routeName true -}}
{{- $timedRuleCount = add $timedRuleCount 1 -}}
{{- end -}}
{{- end -}}
{{- if and (gt $timedRuleCount 0) (ne $timedRuleCount (len $rules)) -}}
{{- fail (printf "%s.routes[%d] must apply generated idle-timeout handling to every rule" $inventoryPath $routeIndex) -}}
{{- end -}}
{{- end -}}

{{- $backendTrafficPolicyNames := dict -}}
{{- $policyTargets := dict -}}
{{- range $policyIndex, $policy := $backendTrafficPolicies -}}
{{- if not (kindIs "map" $policy) -}}
{{- fail (printf "%s.backendTrafficPolicies[%d] must be an object" $inventoryPath $policyIndex) -}}
{{- end -}}
{{- $policyName := get $policy "name" -}}
{{- if or (not (kindIs "string" $policyName)) (empty $policyName) (gt (len $policyName) 253) (not (regexMatch $dnsSubdomainPattern $policyName)) -}}
{{- fail (printf "%s.backendTrafficPolicies[%d].name must be a valid Kubernetes object name" $inventoryPath $policyIndex) -}}
{{- end -}}
{{- if hasKey $backendTrafficPolicyNames $policyName -}}
{{- fail (printf "%s.backendTrafficPolicies contains duplicate name %q" $inventoryPath $policyName) -}}
{{- end -}}
{{- $_ := set $backendTrafficPolicyNames $policyName true -}}
{{- $targetRoute := get $policy "targetRoute" -}}
{{- if or (not (kindIs "string" $targetRoute)) (not (hasKey $routesByName $targetRoute)) -}}
{{- fail (printf "%s.backendTrafficPolicies[%d].targetRoute must reference a generated HTTPRoute" $inventoryPath $policyIndex) -}}
{{- end -}}
{{- if hasKey $policyTargets $targetRoute -}}
{{- fail (printf "%s.backendTrafficPolicies contains multiple policies for route %q" $inventoryPath $targetRoute) -}}
{{- end -}}
{{- if not (hasKey $routesRequiringIdlePolicy $targetRoute) -}}
{{- fail (printf "%s.backendTrafficPolicies[%d] targets a route without timeout annotations" $inventoryPath $policyIndex) -}}
{{- end -}}
{{- $_ := set $policyTargets $targetRoute true -}}
{{- $policySourceIngress := get $policy "sourceIngress" -}}
{{- $targetRouteObject := get $routesByName $targetRoute -}}
{{- if or (not (kindIs "string" $policySourceIngress)) (ne $policySourceIngress (get $targetRouteObject "sourceIngress")) -}}
{{- fail (printf "%s.backendTrafficPolicies[%d].sourceIngress must match its target route" $inventoryPath $policyIndex) -}}
{{- end -}}
{{- $streamIdleTimeout := get $policy "streamIdleTimeout" -}}
{{- if or (not (kindIs "string" $streamIdleTimeout)) (not (regexMatch "^(0|[1-9][0-9]{0,4})s$" $streamIdleTimeout)) -}}
{{- fail (printf "%s.backendTrafficPolicies[%d].streamIdleTimeout must contain 0 to 99999 seconds" $inventoryPath $policyIndex) -}}
{{- end -}}
{{- end -}}
{{- range $routeName, $_ := $routesRequiringIdlePolicy -}}
{{- if not (hasKey $policyTargets $routeName) -}}
{{- fail (printf "%s route %q disables total deadlines but has no BackendTrafficPolicy" $inventoryPath $routeName) -}}
{{- end -}}
{{- end -}}

{{- range $listenerName, $_ := $listenersByName -}}
{{- if not (hasKey $referencedListeners $listenerName) -}}
{{- fail (printf "%s.listeners contains unreferenced listener %q" $inventoryPath $listenerName) -}}
{{- end -}}
{{- end -}}
{{- range $filterName, $_ := $httpRouteFiltersByName -}}
{{- if not (hasKey $referencedHttpRouteFilters $filterName) -}}
{{- fail (printf "%s.httpRouteFilters contains unreferenced filter %q" $inventoryPath $filterName) -}}
{{- end -}}
{{- end -}}
{{- $routingContract := dict
      "listeners" $listeners
      "routes" $routes
      "httpRouteFilters" $httpRouteFilters
      "backendTrafficPolicies" $backendTrafficPolicies
      "tlsSecrets" $tlsSecrets -}}
{{- $actualRoutingContractSha256 := sha256sum (mustToJson $routingContract) -}}
{{- if ne $routingContractSha256 $actualRoutingContractSha256 -}}
{{- fail (printf "%s.source.routingContractSha256 does not match the inventory content" $inventoryPath) -}}
{{- end -}}
{{- mustToJson $inventory -}}
{{- end -}}
