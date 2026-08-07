# Harness Ingress to reusable Gateway API Helm templates

This repository contains a Harness `0.42.1` umbrella-chart fixture and a portable
Bash generator. The generator temporarily renders the upstream Harness
Ingresses, converts their routing topology, and writes environment-neutral Helm
templates for Envoy Gateway `1.8.3`.

The generated YAML does not contain a UT or production namespace, hostname, TLS
Secret, ListenerSet name, or Gateway name. Those values are evaluated by Helm
when the consuming chart is rendered.

## Integration workflow

### 1. Copy the generator

Copy this single executable file into the consuming umbrella-chart repository:

```text
scripts/render-gateway-api.sh
```

It is Bash-only orchestration and requires `helm`, Mike Farah `yq` v4, and
`jq`. It has no Ruby or Python helper.

Do not copy the fixture chart or vendored dependencies from this repository. The
consuming repository should retain its own `Chart.yaml`, Harness dependency, and
existing values.

### 2. Add the shared values

Copy the `gatewayApi` section from `values-base.yaml` into the consuming chart's
shared values. The important shape is:

```yaml
gatewayApi:
  enabled: true
  apiVersion: gateway.networking.k8s.io/v1

  # Only reusable Helm templates are written here.
  outputDirectory: generated
  # Concrete source Ingresses and the Gateway patch are kept separately.
  diagnosticsDirectory: generated-diagnostics

  sourceIngress:
    forceEnabled: true
    # Umbrella dependency alias is "harness" in this repository.
    enabledValuePath: harness.global.ingress.enabled

  # Generated templates read these paths at Helm install/upgrade time.
  runtimeValues:
    hostsPath: harness.global.ingress.hosts
    tlsSecretNamePath: harness.global.ingress.tls.secretName

  provider: envoy-gateway
  envoyGateway:
    version: 1.8.3
    httpRouteFilterApiVersion: gateway.envoyproxy.io/v1alpha1

  parentGateway:
    name: shared-gateway
    namespace: gateway-system
    allowedListeners:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-api.harness.io/allowed: "true"

  listenerSet:
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

Adjust all three dotted paths when the consuming chart has a different
dependency alias:

| Chart structure | Ingress enablement | Runtime hosts |
| --- | --- | --- |
| Dependency named `harness` | `harness.global.ingress.enabled` | `harness.global.ingress.hosts` |
| Harness chart used directly | `global.ingress.enabled` | `global.ingress.hosts` |
| Dependency aliased to `myHarness` | `myHarness.global.ingress.enabled` | `myHarness.global.ingress.hosts` |

Apply the equivalent change to `runtimeValues.tlsSecretNamePath`.

### 3. Keep environment values in the environment files

UT and production keep their existing Harness values. For this fixture they are:

```yaml
# values-ut.yaml
harness:
  global:
    ingress:
      hosts:
        - harness-ut.example.com
      tls:
        secretName: harness-ut-tls
    loadbalancerURL: https://harness-ut.example.com
```

```yaml
# values-prod.yaml
harness:
  global:
    ingress:
      hosts:
        - harness.example.com
      tls:
        secretName: harness-prod-tls
    loadbalancerURL: https://harness.example.com
```

There is no UT- or production-specific Gateway API manifest. Both deployments
use the same generated Helm templates.

The Kubernetes namespace comes from `.Release.Namespace`, not from a generated
literal. Select it normally with Helm:

```sh
helm upgrade --install harness . \
  --namespace harness-ut \
  --create-namespace \
  -f values-base.yaml \
  -f values-ut.yaml

helm upgrade --install harness . \
  --namespace harness-prod \
  --create-namespace \
  -f values-base.yaml \
  -f values-prod.yaml
```

The optional `deployment.namespace` in the example environment files is used
only for the generator's temporary source render. It can be replaced with the
generator's `--namespace` option and is not read by the generated templates.

### 4. Generate once and copy the templates

Use either environment as a representative source render:

```sh
scripts/render-gateway-api.sh \
  -f values-base.yaml \
  -f values-ut.yaml
```

Then copy every generated YAML file into the consuming chart:

```sh
cp generated/*.yaml templates/
```

The files under `generated/` are all Helm templates and are safe to copy as a
set. Do not copy `generated-diagnostics/` into `templates/`.

## What is static and what is evaluated at runtime

The generator captures these from the representative Ingress render:

- Ingress names and paths;
- backend Service names and ports;
- regex match and rewrite behavior;
- timeout behavior; and
- the number of configured external hosts.

The copied templates evaluate these for each Helm deployment:

- `.Release.Namespace`;
- Harness hostname values;
- Harness TLS Secret value;
- parent Gateway name and namespace;
- ListenerSet and ReferenceGrant names.

UT and production must therefore use the same routing topology and number of
external hosts. Their actual hostnames and TLS Secret names may differ. A
generated guard fails Helm rendering when the host count changes. Rerun the
generator whenever a Harness upgrade, component toggle, backend port, path, or
host-count change affects the rendered Ingresses.

The current converter has also been render-tested against the official Harness
`0.43.1` chart. That version adds thirteen paths and the generator incorporates
them when rerun against the upgraded dependency.

## Generated files

`generated/` contains only files intended for `templates/`:

| File | Purpose |
| --- | --- |
| `00-runtime-values-guard.yaml` | Validates the runtime host count |
| `00-listener-set.yaml` | HTTP/HTTPS ListenerSet with runtime hosts and TLS Secret |
| `10-reference-grants.yaml` | Requested narrowly scoped Secret grant |
| `20-http-redirects.yaml` | HTTP-to-HTTPS redirect route |
| `30-http-routes.yaml` | Backend routes derived from the Ingress paths |
| `40-http-route-filters.yaml` | Envoy regex capture/rewrite filters |

`generated-diagnostics/` is not copied:

| File | Purpose |
| --- | --- |
| `ingresses.yaml` | Concrete source Ingresses used for conversion |
| `gateway-allowed-listeners-patch.yaml` | Patch for the externally owned shared Gateway |
| `report.txt` | Counts and untranslated-annotation warnings |
| `rendered-helm.yaml` | Optional complete source render from `--keep-rendered` |

## Shared Gateway namespace access

ListenerSet, HTTPRoutes, HTTPRouteFilters, ReferenceGrant, Services, and TLS
Secret all live in `.Release.Namespace`. The ListenerSet refers across namespaces
to `gatewayApi.parentGateway`.

The shared Gateway must allow ListenerSets from every Harness environment. The
generated diagnostic patch uses a stable namespace-label selector, so it does not
embed UT or production:

```yaml
spec:
  allowedListeners:
    namespaces:
      from: Selector
      selector:
        matchLabels:
          gateway-api.harness.io/allowed: "true"
```

Apply that label to each Harness namespace through the namespace-management
mechanism used by the platform, for example:

```sh
kubectl label namespace harness-ut gateway-api.harness.io/allowed=true
kubectl label namespace harness-prod gateway-api.harness.io/allowed=true
```

The generated ReferenceGrant is retained because it was explicitly requested.
With ListenerSet and TLS Secret colocated, Secret access is namespace-local and
the grant is redundant. The Gateway's `allowedListeners` configuration is what
authorizes the cross-namespace ListenerSet attachment.

## Conversion and validation

Harness uses NGINX regex paths and capture-group rewrites such as `/$2`. Envoy
Gateway `1.8.3` preserves these through
`gateway.envoyproxy.io/v1alpha1` `HTTPRouteFilter` resources using
`ReplaceRegexMatch`.

The generator also:

- splits HTTPRoutes at the Gateway API maximum of 16 rules;
- resolves numeric and named Service ports;
- maps `proxy-read-timeout` to `backendRequest` timeouts;
- reports untranslated NGINX annotations;
- rejects unresolved backends and inconsistent TLS/host inputs;
- checks route/filter references and generated namespaces; and
- verifies that concrete environment values did not leak into the templates.

Relevant upstream documentation:

- [Envoy Gateway 1.8.3 installation](https://gateway.envoyproxy.io/v1.8/install/install-yaml/)
- [Envoy Gateway regex URL rewrites](https://gateway.envoyproxy.io/v1.8/tasks/traffic/http-urlrewrite/)
- [Gateway API ListenerSet attachment](https://gateway-api.sigs.k8s.io/guides/user-guides/listener-set/)
