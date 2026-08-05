# Harness Platform with a Central Envoy Gateway

This project derives Gateway API resources from the Ingress and Service
manifests rendered by Harness Platform. It does not use Harness' native
Gateway API templates and does not vendor the Harness chart.

The generated resources attach to the fixed central Gateway
`envoy-gateway-apps/apps-gateway`. The `ListenerSet`, `HTTPRoute`, Envoy
`HTTPRouteFilter`, `BackendTrafficPolicy`, and `ReferenceGrant` resources are
created in the Harness namespace. The optional Cilium policy permits the
central Envoy data plane to reach workloads in that namespace.

The implementation is tested with:

- Harness Platform chart 0.42.1
- Envoy Gateway 1.8.3
- Gateway API 1.5.1 CRDs
- Helm 3.19 and Helm 4.2

## Why Generation Is a Separate Step

A Helm template cannot inspect Kubernetes resources rendered earlier in the
same Helm operation or by another release. This project therefore uses a
two-stage, environment-specific build:

```text
Harness chart + ordered environment values
                |
                v
helm template with global.gatewayAPI.enabled=false
                |
                v
rendered Ingresses and Services
                |
                v
normalized routing inventory
                |
                v
ephemeral copy of the existing custom chart
                |
                v
Gateway API resources and optional NetPol
```

The generator never changes either source chart and rejects output paths
inside a local Harness chart or the custom chart. It packages the custom chart
and adds `generated/harness-gateway-inventory.json` to a new output directory.
Keep that output in a temporary or explicitly ignored location outside tracked
source, as the examples below do.

Because the inventory comes from resources that Helm actually rendered, an
Ingress omitted by an environment's values produces no HTTPRoute. A later
upgrade of the same custom-chart Helm release also removes the previously
owned route. Merely running `helm template` does not reconcile or delete live
cluster resources; the existing chart delivery process must deploy the new
output with its usual prune or Helm-upgrade behavior.

The generator does not remove or modify Harness Ingress resources. If they
are installed and an Ingress controller watches their class, the Ingress and
Gateway entry points operate in parallel. This is useful during migration but
must be an intentional deployment decision.

## Prerequisites

- The central `apps-gateway` Gateway already exists in
  `envoy-gateway-apps`.
- The Gateway permits ListenerSets from the Harness namespace.
- TLS Secrets of type `kubernetes.io/tls` exist in the Harness namespace.
- Harness and Looker use concrete, distinct FQDNs.
- Bash, Helm, `awk`, and `tar` are available where the chart is generated.
- The target cluster Kubernetes version is known and passed explicitly to the
  generator so Helm capability-dependent rendering is reproducible. Envoy
  Gateway 1.8 supports Kubernetes 1.32 through 1.35 according to its
  [compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/).
- A repository checkout additionally needs `curl` and either `sha256sum` or
  `shasum` to download and verify the pinned Harness test chart.
- The environment's Harness values keep native Gateway API output disabled:

```yaml
global:
  gatewayAPI:
    enabled: false
```

The generator applies this value again as its final render override. Keeping
it in the deployed Harness values prevents native and generated routes from
coexisting accidentally and avoids the Harness 0.42.1 `grpcRoutes` rendering
failure.

## Minimal Overlay Values

The chart introduces only two switches:

```yaml
harnessGatewayOverlay:
  enabled: true

  ciliumNetworkPolicy:
    enabled: false
```

Do not duplicate FQDNs, TLS Secret names, feature flags, paths, Service names,
or ports in these values. The generator discovers them from the Harness render.
An environment file such as `values-nonprod.yaml` or `values-prod.yaml` should
contain only overlay-specific differences. In most environments that means no
additional values beyond the block above.

## Generate a Standalone Environment Chart

Obtain the official Harness chart through the normal Harness installation
workflow, or, from a repository checkout, download and verify the pinned
0.42.1 artifact used by the tests:

```sh
bash ./scripts/fetch-platform-chart /tmp/harness-platform-0.42.1
```

The generator accepts only a local chart directory or chart archive. Resolve
repository references beforehand so an environment build cannot silently move
to a newer upstream chart.

Generate non-production output using the exact ordered Harness values used for
that environment:

```sh
bash ./scripts/generate-gateway-api \
  --harness-chart /tmp/harness-platform-0.42.1 \
  --custom-chart . \
  --output-chart /tmp/harness-gateway-nonprod \
  --namespace harness-nonprod \
  --release-name harness \
  --kube-version 1.34.0 \
  --allow-implementation-specific-regex-ordering \
  --values /path/to/harness-values-common.yaml \
  --values /path/to/harness-values-nonprod.yaml
```

Generate production into a different directory and use the production Harness
values:

```sh
bash ./scripts/generate-gateway-api \
  --harness-chart /tmp/harness-platform-0.42.1 \
  --custom-chart . \
  --output-chart /tmp/harness-gateway-prod \
  --namespace harness-prod \
  --release-name harness \
  --kube-version 1.34.0 \
  --allow-implementation-specific-regex-ordering \
  --values /path/to/harness-values-common.yaml \
  --values /path/to/harness-values-prod.yaml
```

Replace `1.34.0` with the target environment's supported Kubernetes version.
The output path must not already exist. This prevents an incomplete build
from overwriting a previously generated environment chart.

If the real Harness installation uses capability-dependent Helm rendering,
pass the same repeatable `--api-versions` values to the generator. The
Kubernetes version is always required. The inventory records that version,
the generator's Helm version, and every explicit API version for auditability.
Consolidate `--set`, `--set-string`, and `--set-file` installation overrides
into the ordered Harness values files used here; the generator intentionally
accepts values files as its configuration contract.

Render the generated chart locally:

```sh
helm template custom-manifests /tmp/harness-gateway-nonprod \
  --namespace harness-nonprod \
  --values /tmp/harness-gateway-nonprod/values-base.yaml \
  > /tmp/harness-gateway-nonprod.yaml
```

With the CRDs installed in a test cluster, the result can also be validated
without changing cluster state:

```sh
kubectl apply --dry-run=server \
  --filename /tmp/harness-gateway-nonprod.yaml
```

This repository does not prescribe how the custom chart is installed. When
used standalone, it can be installed with a normal `helm upgrade --install`.
When its templates are copied into an existing custom chart, that chart's
existing delivery process owns installation and reconciliation.

## Integrate with an Existing Custom Chart

The intended production setup is an existing chart that already contains
other custom manifests under `templates/` and has its own `values.yaml`.

### Copy the Stable Templates

Copy these files into the existing chart's `templates/` directory:

<!-- markdownlint-disable MD013 -->

| Source | Recommended destination |
| --- | --- |
| `templates/_helpers.tpl` | `templates/_harness-gateway-api.tpl` |
| `templates/validation.yaml` | `templates/harness-gateway-api-validation.yaml` |
| `templates/listenersets.yaml` | `templates/harness-gateway-api-listenersets.yaml` |
| `templates/httproutes.yaml` | `templates/harness-gateway-api-httproutes.yaml` |
| `templates/backendtrafficpolicies.yaml` | `templates/harness-gateway-api-backendtrafficpolicies.yaml` |
| `templates/referencegrant.yaml` | `templates/harness-gateway-api-referencegrant.yaml` |
| `templates/ciliumnetworkpolicy.yaml` | `templates/harness-gateway-api-ciliumnetworkpolicy.yaml` |

<!-- markdownlint-enable MD013 -->

Do not replace the existing chart's `_helpers.tpl`; use the distinct filename
shown above. The named templates use the `harness-gateway-api.*` prefix.

Copy the generator and its internal converter while preserving their relative
paths:

```text
scripts/
|-- generate-gateway-api
`-- ingress-converter/
    |-- Chart.yaml
    |-- values.yaml
    `-- templates/inventory.yaml
```

Invoke the generator with `bash`. Helm chart archives do not preserve its
executable mode reliably.

### Merge Only the New Values

Merge the minimal `harnessGatewayOverlay` block into the existing custom
chart's `values.yaml`. Do not copy Harness `global`, `looker`, or Service values
into the custom chart.

The effective values used when the existing custom chart is deployed must
enable the overlay:

```yaml
harnessGatewayOverlay:
  enabled: true
  ciliumNetworkPolicy:
    enabled: false
```

The `--values` arguments passed to the generator configure only the first-pass
Harness render. They are not automatically passed to the later custom-chart
deployment.

If the existing chart has a strict `values.schema.json`, merge only the
`harnessGatewayOverlay` property definition from this repository. Do not
replace the existing schema.

### Build an Ephemeral Copy of the Existing Chart

Point `--custom-chart` at the existing chart:

```sh
bash ./scripts/generate-gateway-api \
  --harness-chart /path/to/platform-0.42.1 \
  --custom-chart /path/to/custom-chart \
  --output-chart /tmp/custom-chart-nonprod \
  --namespace harness-nonprod \
  --release-name harness \
  --kube-version 1.34.0 \
  --allow-implementation-specific-regex-ordering \
  --values /path/to/harness-values-common.yaml \
  --values /path/to/harness-values-nonprod.yaml
```

The output is a Helm-package-equivalent copy of the existing custom chart with
one additional machine-generated inventory file. Files ignored by the source
chart's `.helmignore` are not copied. Render or deploy
`/tmp/custom-chart-nonprod` through the existing chart workflow. Build
production into a separate output directory.

Ensure the existing chart's `.helmignore` does not exclude
`generated/harness-gateway-inventory.json`; Helm templates cannot read ignored
chart files.

Never commit generated inventories or publish them publicly. An internally
published environment chart necessarily embeds its inventory. Inventories can
contain private hostnames, Kubernetes namespace names, TLS Secret names, and
internal Service names even though they contain no Secret data.

## Conversion Contract

The converter reads only rendered Kubernetes APIs, not Harness template names
or helper definitions. This limits coupling to Harness internals and makes a
future chart update visible through the generated contract tests.

It performs the following conversions:

- One HTTPS ListenerSet listener per unique hostname and TLS Secret.
- One or more HTTPRoutes per rendered Ingress and hostname.
- A maximum of 16 rules per HTTPRoute, as required by Gateway API.
- Numeric Ingress backend ports directly.
- Named Ingress backend ports by resolving the rendered Service.
- `Exact` paths to `Exact` and `Prefix` paths to `PathPrefix`.
- Regex Ingress paths to case-insensitive Envoy-supported `RegularExpression`
  matches, matching ingress-nginx's regex case behavior.
- NGINX regex rewrites to Envoy `HTTPRouteFilter` resources using
  `ReplaceRegexMatch`.
- NGINX read/send inactivity timeouts to an Envoy
  `BackendTrafficPolicy.timeout.http.streamIdleTimeout`. The corresponding
  HTTPRoute total request deadlines are set to `0s`; if read and send values
  differ, the stricter value is used and the generator warns explicitly.
- TLS Secret names to an exact-name, least-privilege ReferenceGrant.

The generator fails instead of silently dropping unsupported behavior. This
includes unknown `nginx.ingress.kubernetes.io/*` annotations, hostless or
wildcard rules, conflicting TLS Secrets, missing Services or named Service
ports, cross-namespace Ingresses, resource backends, default backends, and
regular expressions that Envoy's RE2-compatible matcher cannot compile.
Numeric Ingress ports are preserved after verifying that the rendered Service
exists. A numeric port absent from that Service produces an explicit warning;
Harness Platform 0.42.1 contains one such upstream contract.

Ingress-nginx length-orders regex locations across a hostname, whereas
Gateway API leaves regular-expression precedence implementation-specific.
Harness Platform 0.42.1 emits overlapping regex paths, so the generator fails
closed unless the environment build explicitly includes:

```text
--allow-implementation-specific-regex-ordering
```

That flag acknowledges a reviewed Envoy Gateway compatibility risk; it does
not change or guarantee routing order. The acknowledgment is recorded in the
inventory. The generator also deduplicates identical matches, fails on
conflicting duplicate matches (including different inactivity timeouts), and
emits detailed regex-ordering warnings. Validate representative overlapping
paths against Envoy Gateway before production rollout and again after any
Harness or Envoy Gateway update.

Ingress controller annotations are implementation-specific and do not always
have exact Gateway API equivalents. Review the
[Gateway API migration guide](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/)
when a Harness update introduces a new annotation or routing behavior.

## TLS ReferenceGrant

The generated ListenerSet references TLS Secrets in its own namespace. The
ReferenceGrant additionally declares that the fixed central Gateway namespace
may reference only the exact TLS Secret names discovered from the Ingresses.
It is retained as an explicit trust declaration as requested. It does not
replace the Envoy Gateway controller's Kubernetes RBAC permissions.

## Cilium Network Policy

The policy is disabled by default. Enable it only after verifying the actual
Envoy data-plane labels and the existing default-deny policies:

```yaml
harnessGatewayOverlay:
  enabled: true
  ciliumNetworkPolicy:
    enabled: true
```

The policy is additive (`enableDefaultDeny.ingress: false`). It permits pods
from `envoy-gateway-apps` owned by `apps-gateway` to reach workloads in the
Harness namespace. It selects all Harness pods and ports because the Platform
chart creates many backends with different labels and ports.

## Upgrade and Verification Contract

From a repository checkout, run the complete contract suite before every
Harness, Gateway API, or Envoy Gateway upgrade:

```sh
bash ./scripts/test
```

The test downloads the pinned Harness chart into a temporary directory,
verifies its SHA-256, and removes it afterward. For offline use:

```sh
HARNESS_PLATFORM_ARCHIVE=/path/to/platform-0.42.1.tgz bash ./scripts/test
```

To test an already extracted chart:

```sh
HARNESS_PLATFORM_CHART=/path/to/platform bash ./scripts/test
```

The suite verifies complete Ingress/backend and TLS parity, named Service-port
resolution, numeric-port warnings, case-insensitive rewrite filters, Envoy idle
timeout policies, ListenerSet parents, route removal, deterministic output,
exact path/filter/timeout associations, explicit regex-risk acknowledgment,
render-capability recording, `.helmignore` failure handling, the Cilium opt-in,
native-Gateway-resource rejection, unsupported-annotation and incompatible-
regex failures, and source chart immutability.

## License, Attribution, and Disclaimer

Except where otherwise noted, this project is licensed under the
[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution details.

No Harness Platform chart or Harness source code is distributed here. The
separately downloaded compatibility target and checksum are documented in
[UPSTREAM.md](UPSTREAM.md).

This is an independent, community-maintained project. It is not affiliated
with, endorsed by, sponsored by, or supported by Harness Inc., Envoy Gateway,
the Cloud Native Computing Foundation, or the Cilium project. Product names
and trademarks belong to their respective owners.

The software is provided **AS IS**, without warranties or conditions of any
kind. The warranty disclaimer and limitation of liability in Sections 7 and 8
of the Apache License 2.0 apply. Validate generated resources in a
non-production environment before deployment.

For contribution, security-reporting, and support expectations, see
[CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[SUPPORT.md](SUPPORT.md).
