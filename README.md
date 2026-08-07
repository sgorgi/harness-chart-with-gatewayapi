# Harness 0.42.1 Gateway API generator

This repository is both:

1. a standalone Harness `0.42.1` rendering fixture; and
2. a portable, single-file Gateway API generator intended to be copied into a
   different umbrella-chart repository.

The generator temporarily renders the chart's existing Ingress resources and
converts their hosts, paths, Services, ports, TLS Secrets, and supported NGINX
annotations into resources for Envoy Gateway `1.8.3`.

## Integrating only the generator

### Files to copy

Copy exactly one executable file:

```text
scripts/render-gateway-api.sh
```

The script is self-contained Bash. It has no Ruby or Python helper. It expects
`helm`, Mike Farah `yq` v4, and `jq` to be installed.

Do **not** copy these fixture files into the consuming repository:

```text
Chart.yaml
charts/
generated/
values-base.yaml
values-ut.yaml
values-prod.yaml
values-metrics.yaml
```

The consuming repository should keep its own Chart, vendored/dependent Harness
chart, and existing values files. The generated directory is reproducible output,
not part of the portable generator.

### Shared values to copy

Copy the following `gatewayApi` key into the consuming repository's shared/base
values file. Adjust `sourceIngress.enabledValuePath` to the chart structure:

- an umbrella dependency named `harness`: `harness.global.ingress.enabled`
- the Harness chart used directly: `global.ingress.enabled`
- another dependency alias: `<alias>.global.ingress.enabled`

```yaml
gatewayApi:
  enabled: true
  apiVersion: gateway.networking.k8s.io/v1

  sourceIngress:
    forceEnabled: true
    enabledValuePath: harness.global.ingress.enabled

  provider: envoy-gateway
  envoyGateway:
    version: 1.8.3
    httpRouteFilterApiVersion: gateway.envoyproxy.io/v1alpha1

  parentGateway:
    # The existing shared Gateway is the only generated-resource dependency
    # outside the Harness release namespace.
    name: shared-gateway
    namespace: gateway-system

  listenerSet:
    # Namespace is intentionally omitted. The generator always uses the
    # effective Harness release namespace.
    name: harness
    http:
      enabled: true
      port: 80
      redirectToHttps: true
      redirectStatusCode: 301
    https:
      enabled: true
      port: 443

  referenceGrant:
    name: harness-listenerset-secrets

  httpRoute:
    maxRules: 16

  commonLabels:
    app.kubernetes.io/part-of: company-harness
    app.kubernetes.io/managed-by: harness-gateway-generator
```

Optionally add the release name to shared values. Otherwise pass `--release`:

```yaml
deployment:
  releaseName: harness
```

The `deployment` key is generator input; Helm ignores it unless the consuming
umbrella chart also defines templates that use it.

### Environment-specific values to copy

Add this shape to every environment values file. These are the values that should
differ between UT, production, and future environments:

```yaml
deployment:
  namespace: harness-environment

gatewayApi:
  outputDirectory: generated/environment
  listenerSet:
    name: harness-environment
  referenceGrant:
    name: harness-environment-listenerset-secrets
```

`deployment.namespace` is the namespace used for the Helm render and for every
generated Harness-side resource: ListenerSet, ReferenceGrant, redirect
HTTPRoute, backend HTTPRoute, and Envoy HTTPRouteFilter. It can be overridden
with `--namespace`; `gatewayApi.outputDirectory` can be overridden with
`--output`.

The shared Gateway name and namespace live only in shared/base values because
they are common to UT and production in this setup. Override them in an
environment file only if that environment actually uses a different Gateway.

### Existing Harness values to keep

Do not copy the complete `harness:` blocks from this repository. They exist so
this small fixture can render independently. The consuming repository should keep
its existing upstream Harness values, but those values must result in rendered
Ingresses containing the intended:

- external hostname(s);
- TLS Secret name(s);
- backend Service names and ports; and
- path and NGINX rewrite annotations.

For this chart, the relevant upstream values happen to look like:

```yaml
harness:
  global:
    ingress:
      enabled: false
      hosts:
        - harness-environment.example.com
      tls:
        enabled: true
        secretName: harness-environment-tls
    loadbalancerURL: https://harness-environment.example.com
```

Keep `ingress.enabled: false` for the real Gateway-only deployment. The generator
temporarily overrides it to `true` while running `helm template`, extracts the
Ingresses, and discards the temporary complete render. This repository's
`harness.global.ingress.className`, `harness.global.gatewayAPI.enabled`, database
defaults, and other chart values are fixture concerns rather than generator
configuration.

## Run the generator

From the umbrella-chart root:

```sh
scripts/render-gateway-api.sh \
  -f values-base.yaml \
  -f values-environment.yaml
```

Values files use normal Helm precedence and may be repeated:

```sh
scripts/render-gateway-api.sh \
  -f values-base.yaml \
  -f values-environment.yaml \
  -f values-local-overrides.yaml \
  --chart . \
  --namespace harness-custom \
  --output generated/custom
```

Use `--keep-rendered` only for diagnostics. The retained complete render contains
the temporarily enabled source Ingresses and must not be applied as a Gateway-only
deployment.

## Conversion behavior

Harness 0.42.1 relies heavily on paths such as `/authz(/|$)(.*)` with
`nginx.ingress.kubernetes.io/rewrite-target: /$2`. Standard Gateway API rewrites
cannot substitute regex capture groups. Envoy Gateway `1.8.3` supports the
`gateway.envoyproxy.io/v1alpha1` `HTTPRouteFilter` extension with
`ReplaceRegexMatch`, so the generator produces one filter for each rewritten path.

It also:

- maps NGINX `proxy-read-timeout` to `HTTPRoute.rules[].timeouts.backendRequest`;
- splits routes at the Gateway API limit of 16 rules per HTTPRoute;
- resolves numeric and named Ingress Service ports;
- creates HTTP-to-HTTPS redirect routes;
- supports multiple values files, hosts, environments, and TLS Secrets; and
- reports every untranslated NGINX annotation instead of silently dropping it.

The default Harness NG fixture currently produces 30 Ingresses with 206 paths,
38 backend HTTPRoutes, one redirect route, and 204 regex rewrite filters.

## Generated files

Each configured output directory contains:

| File | Purpose | Apply? |
| --- | --- | --- |
| `ingresses.yaml` | Extracted source Ingresses for review | No |
| `00-listener-set.yaml` | HTTP/HTTPS listeners, TLS refs, allowed routes | Yes |
| `10-reference-grants.yaml` | Narrow Secret-access declaration in the Harness namespace | Yes |
| `20-http-redirects.yaml` | HTTP-to-HTTPS redirect routes | Yes |
| `30-http-routes.yaml` | Backend routes derived from Ingress rules | Yes |
| `40-http-route-filters.yaml` | Envoy regex capture/rewrite filters | Yes |
| `all.yaml` | All directly applicable generated resources | Yes |
| `gateway-allowed-listeners-patch.yaml` | Merge patch for the existing Gateway | Separately |
| `report.txt` | Counts, selected parents/namespaces, warnings | Review |

## Namespace and cross-namespace attachment

The ListenerSet, HTTPRoutes, Envoy HTTPRouteFilters, ReferenceGrant, Services,
and TLS Secret all live in the effective Harness release namespace. The only
cross-namespace relationship is the ListenerSet's `parentRef` to the existing
shared Gateway:

```yaml
spec:
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: shared-gateway
    namespace: gateway-system
```

HTTPRoutes attach locally to the ListenerSet and `allowedRoutes.namespaces.from`
defaults to `Same`. The TLS certificate reference is local too, so Gateway API
does not require a ReferenceGrant for Secret access. The generator still emits
the requested narrowly scoped ReferenceGrant in the Harness namespace; it does
not authorize the ListenerSet-to-Gateway attachment and is redundant while the
ListenerSet and Secret remain colocated.

The existing Gateway authorizes the cross-namespace ListenerSet through
`allowedListeners`. Review the generated patch because applying it replaces the
Gateway's current `allowedListeners` block:

```sh
kubectl patch gateway shared-gateway \
  --namespace gateway-system \
  --type merge \
  --patch-file generated/environment/gateway-allowed-listeners-patch.yaml

kubectl apply --server-side --filename generated/environment/all.yaml
```

Before moving traffic, verify that the ListenerSet and every HTTPRoute report
positive `Accepted`, `Programmed`, and `ResolvedRefs` conditions and test
representative UI, API, streaming, and long-running Harness paths.

## Envoy Gateway 1.8.3 prerequisites

Envoy Gateway `1.8.3` expects compatible Gateway API and Envoy Gateway CRDs. Its
published installation includes the required CRDs; if CRDs are managed separately,
upgrade them before the controller. The generator targets:

```text
ListenerSet / HTTPRoute / ReferenceGrant: gateway.networking.k8s.io/v1
HTTPRouteFilter:                         gateway.envoyproxy.io/v1alpha1
```

Relevant upstream documentation:

- [Envoy Gateway 1.8.3 installation and CRDs](https://gateway.envoyproxy.io/v1.8/install/install-yaml/)
- [Envoy Gateway 1.8 regex URL rewrites](https://gateway.envoyproxy.io/v1.8/tasks/traffic/http-urlrewrite/)
- [Gateway API ListenerSet attachment](https://gateway-api.sigs.k8s.io/guides/user-guides/listener-set/)
