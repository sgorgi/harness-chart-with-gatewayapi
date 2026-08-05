# Harness Platform with a Central Envoy Gateway

This chart extends Harness Platform 0.42.1 with a namespace-scoped
`ListenerSet`, TLS termination, a narrowly scoped `ReferenceGrant`, and the few
routes that the Harness chart does not generate as `HTTPRoute` resources.
The central Gateway is intentionally fixed to
`envoy-gateway-apps/apps-gateway`.

The generic Harness routes are neither duplicated nor vendored. They come
directly from the separately installed official Harness chart. This allows
new or changed Ingress definitions to be adopted as automatically as possible
during a Harness upgrade. A small post-renderer adds only the `group` and
`kind` parent fields that Harness 0.42.1 does not yet support to these native
routes. This repository contains only the overlay and its compatibility
tooling, not a copy of the Harness Platform chart.

## Prerequisites

- Envoy Gateway 1.8.3 with the corresponding Gateway API 1.5.1 CRDs
- An existing `apps-gateway` Gateway in the `envoy-gateway-apps` namespace
- `Gateway.spec.allowedListeners` permits ListenerSets from the Harness
  namespace
- TLS Secrets of type `kubernetes.io/tls` exist in the Harness namespace
- Ruby with the standard `psych` library for the Helm post-renderer
- `curl`, `tar`, and SHA-256 tooling when running the contract tests without a
  locally supplied Harness chart

The ListenerSet, HTTPRoutes, and ReferenceGrant are always created in
`.Release.Namespace`. There is intentionally no separate namespace value.

## Values Contract

`values.yaml` and `values-base.yaml` contain only the two switches introduced
by this overlay. FQDNs, TLS Secrets, and feature flags remain in the existing
Harness values file. To enable Gateway API output, that file must contain the
following existing Harness values or their equivalents:

```yaml
global:
  ingress:
    enabled: true
    hosts:
      - harness.example.invalid
    tls:
      enabled: true
      secretName: harness-tls

  gatewayAPI:
    enabled: true
    parentRef:
      name: harness-listeners
      namespace: harness
      sectionName: harness-https

  ng:
    enabled: true

  cg:
    enabled: false

  ngcustomdashboard:
    enabled: true

looker:
  ingress:
    hosts:
      - looker.example.invalid
    tls:
      secretName: looker-tls
```

`harness.example.invalid`, `looker.example.invalid`, `harness`,
`harness-tls`, and `looker-tls` are placeholders. If Looker uses the same TLS
Secret as Harness, `looker.ingress.tls.secretName` may be omitted. When
`global.ngcustomdashboard.enabled` is disabled, neither the Looker listener
nor the Looker route is rendered, and no Looker values are required.
`global.ng.enabled`, `global.cg.enabled`, and
`global.ngcustomdashboard.enabled` must be explicit Boolean values so that
the overlay and Platform chart do not assume different subchart defaults.
The agreed architecture accepts exactly one concrete Harness FQDN and, when
Looker is enabled, exactly one distinct Looker FQDN.

## Integrating the Resources into an Existing Custom Chart

You can add these Gateway API resources to an existing Helm chart that already
contains other custom manifests. The custom chart must be installed in the
same namespace as Harness because the ListenerSet, HTTPRoutes, ReferenceGrant,
Services, and TLS Secrets are namespace-local.

This integration ends at the custom chart boundary: once the templates and
values below are present, they render as ordinary resources of that chart.
How the existing chart is installed or reconciled is intentionally outside
the scope of this repository. No separate Helm release is required for these
copied resources.

### 1. Copy the Templates

Copy the following files from this repository into the existing chart's
`templates/` directory. The destination names are recommendations that avoid
overwriting generic filenames already present in the chart; Helm does not
require the source filenames to be preserved.

<!-- markdownlint-disable MD013 -->

| Source file | Recommended destination | Purpose |
| --- | --- | --- |
| `templates/_helpers.tpl` | `templates/_harness-gateway-api.tpl` | Fixed Gateway contract, names, labels, and annotations |
| `templates/validation.yaml` | `templates/harness-gateway-api-validation.yaml` | Fail-fast validation of the existing Harness values |
| `templates/listenersets.yaml` | `templates/harness-gateway-api-listenersets.yaml` | Harness and optional Looker HTTPS listeners |
| `templates/httproutes.yaml` | `templates/harness-gateway-api-httproutes.yaml` | NextGen UI and optional Looker routes not emitted by Harness 0.42.1 |
| `templates/referencegrant.yaml` | `templates/harness-gateway-api-referencegrant.yaml` | Narrow TLS Secret trust declaration for the centralized Gateway |
| `templates/ciliumnetworkpolicy.yaml` | `templates/harness-gateway-api-ciliumnetworkpolicy.yaml` | Optional Envoy-to-Harness Cilium allow rule |

<!-- markdownlint-enable MD013 -->

Copy `_helpers.tpl` under the recommended distinct filename instead of
replacing the custom chart's existing `_helpers.tpl`. The named templates
inside it use the `harness-gateway-api.*` prefix and must remain available to
all five remaining templates.

All six files can be copied safely. The CiliumNetworkPolicy template remains
dormant while its value is `false`. If Cilium is not used at all, that one
template may be omitted.

Do not replace the existing chart's `Chart.yaml`, `values.yaml`, or
`values.schema.json` with files from this repository. The test fixtures,
scripts, download helper, and standalone chart metadata are not required by
the combined custom chart.

### 2. Add Only the New Values

Merge only this block into the existing custom chart's `values.yaml`:

```yaml
harnessGatewayOverlay:
  enabled: true

  ciliumNetworkPolicy:
    enabled: false
```

These are the only values introduced by the overlay. Keep the Cilium policy
disabled until the Envoy data-plane labels and existing default-deny policies
have been verified.

If the custom chart has a strict `values.schema.json`, merge the
`harnessGatewayOverlay` property definition from this repository's schema
into its existing root `properties`. Do not replace the existing schema. A
schema with `additionalProperties: false` must also declare the reused
`global`, `looker`, and `next-gen-ui` paths listed below, or Helm will reject
them before rendering.

### 3. Supply the Existing Harness Values

The copied templates intentionally reuse the existing Harness configuration
instead of introducing duplicate FQDN, Secret, Service, or feature values.
They therefore need these existing Harness paths in the values passed to the
custom chart:

- `global.ingress.enabled`, `global.ingress.hosts`, and
  `global.ingress.tls.{enabled,secretName}`
- `global.gatewayAPI.enabled` and `global.gatewayAPI.parentRef`
- Explicit Boolean values for `global.ng.enabled`, `global.cg.enabled`, and
  `global.ngcustomdashboard.enabled`
- When Looker is enabled, `looker.ingress.hosts` and, when it does not use the
  Harness certificate, `looker.ingress.tls.secretName`
- Existing `next-gen-ui` or `looker` name and Service-port overrides, if they
  differ from the Harness 0.42.1 defaults

The exact required values and placeholders are shown in the Values Contract
above. In particular, the native Harness HTTPRoutes must use:

```yaml
global:
  gatewayAPI:
    enabled: true
    parentRef:
      name: harness-listeners
      namespace: harness
      sectionName: harness-https
```

Replace `harness` with the namespace used by both the Harness resources and
the custom chart. The namespace may also be omitted from this ParentRef; when
present, it must equal the custom chart's release namespace.

Add only these non-secret names, hostnames, ports, and feature flags to the
existing chart values that are used for the target environment. Do not copy
credentials, private keys, or Secret contents from the Harness values. The
templates require only the Kubernetes Secret names.

### 4. Resulting Resources and Scope

After the files and values are merged, the existing custom chart can render:

- One `ListenerSet` with the Harness HTTPS listener
- A second listener when Looker is enabled
- One narrowly scoped `ReferenceGrant` for the TLS Secret names
- The `harness-ui` HTTPRoute when NextGen UI is enabled without Classic UI
- The Looker HTTPRoute when Looker is enabled
- The optional `CiliumNetworkPolicy` when explicitly enabled

The copied files do not install or modify the centralized Gateway and do not
copy the generic Harness service routes. Those generic HTTPRoutes remain owned
by the native Harness Gateway API output. Any post-rendering required by the
Harness Platform release remains part of that separate Harness deployment
workflow; no post-renderer script needs to be copied into the existing custom
chart.

### 5. Optional Render Verification

The chart's existing delivery process is responsible for applying the
resources. As an optional local check, render the custom chart with the target
namespace and its environment values:

```sh
helm template custom-manifests /path/to/custom-chart \
  --namespace harness \
  -f /path/to/custom-environment-values.yaml \
  > /tmp/custom-manifests.yaml
```

With the matching CRDs installed in a test cluster, a server-side dry run can
validate the generated file without installing a separate overlay release:

```sh
kubectl apply --dry-run=server -f /tmp/custom-manifests.yaml
```

The render should contain one ListenerSet and one ReferenceGrant. It should
also contain the `harness-ui` HTTPRoute when NextGen UI is enabled without
Classic UI, the `looker` HTTPRoute and listener when Looker is enabled, and a
CiliumNetworkPolicy only when its explicit opt-in value is `true`.

When redistributing a chart containing these copied templates, retain the
Apache-2.0 license and attribution from this repository.

## Rendering and Installation

This section applies only when using this repository as a standalone overlay
chart. Skip it when the files have been copied into an existing custom chart.

First, install the overlay in the same namespace as Harness:

```sh
helm upgrade --install harness-gateway-api . \
  --namespace harness \
  --create-namespace \
  -f /path/to/existing-harness-values.yaml \
  -f values-base.yaml
```

Obtain Harness Platform 0.42.1 from the official Harness release. The helper
below downloads the official archive, verifies its pinned SHA-256, and
extracts it outside this repository:

```sh
./scripts/fetch-platform-chart /tmp/harness-platform-0.42.1
```

You may instead obtain the chart through the official
[Harness installation workflow](https://developer.harness.io/docs/self-managed-enterprise-edition/install/install-using-helm/).

Then install Harness with its native Gateway API output and the post-renderer.
Helm 4 expects a plugin name, so register the included plugin directly from
this repository once:

```sh
helm plugin install ./scripts

helm upgrade --install harness /tmp/harness-platform-0.42.1 \
  --namespace harness \
  -f /path/to/existing-harness-values.yaml \
  --post-renderer harness-listenerset-parentref
```

With Helm 3, the executable script can still be used directly:

```sh
helm upgrade --install harness /tmp/harness-platform-0.42.1 \
  --namespace harness \
  -f /path/to/existing-harness-values.yaml \
  --post-renderer ./scripts/listenerset-parentref-post-renderer
```

The post-renderer fails closed: conflicting ParentRefs, an incorrect listener
section, cross-namespace targets, or invalid YAML abort the Helm operation.
The operation also fails if Harness generates no native HTTPRoute or attaches
one unexpectedly. The post-renderer does not modify unrelated resources and
is idempotent. It also repairs two missing YAML document separators in the
upstream 0.42.1 chart so that no `HTTPRouteFilter` resources are lost.

The same post-renderer must be used for every subsequent `helm upgrade` of
this Platform release. Otherwise, Helm would store the incomplete upstream
ParentRefs again.

## TLS References and ReferenceGrant

The ListenerSet `certificateRefs` are namespace-local and point to the exact
Secret names from the existing Harness values. The additional ReferenceGrant
declares that Gateways from the central Gateway namespace may reference only
these Secrets. Under the current Gateway API semantics, the namespace-local
ListenerSet reference does not technically require this grant. It remains as
an explicit and narrowly scoped trust declaration. A ReferenceGrant does not
replace the controller's Kubernetes RBAC permissions.

## Cilium Network Policy

The Cilium policy is disabled by default. Enable it only after verifying the
actual Envoy data-plane labels:

```yaml
harnessGatewayOverlay:
  enabled: true
  ciliumNetworkPolicy:
    enabled: true
```

The policy is additive (`enableDefaultDeny.ingress: false`) and permits only
pods from `envoy-gateway-apps` that belong to `apps-gateway`, as identified by
the two Envoy ownership labels. It selects all Harness pods and ports because
the Platform chart creates many backends with different labels and ports.
Before enabling it, verify the labels on the generated Envoy pods and review
the existing deny policies in the cluster.

## Upgrade Contract

Run the following command before every Harness or Envoy Gateway upgrade:

```sh
./scripts/test
```

By default, the test downloads the pinned official Harness chart into a
temporary directory, verifies its SHA-256, and removes it after the run. For
an offline run, provide the official archive explicitly:

```sh
HARNESS_PLATFORM_ARCHIVE=/path/to/platform-0.42.1.tgz ./scripts/test
```

To test a different already extracted chart, provide its directory:

```sh
HARNESS_PLATFORM_CHART=/path/to/platform ./scripts/test
```

The test renders Platform and the overlay, verifies ParentRefs, listeners,
Secrets, special-case routes, the Cilium opt-in behavior, and post-renderer
idempotence, and confirms that it does not modify the supplied Platform chart.
Changes to the native Harness Gateway API output therefore fail visibly
instead of silently continuing with an outdated, hard-coded route list.

On Platform 0.42.1, a Classic Generation-only configuration
(`global.cg.enabled=true`, `global.ng.enabled=false`) without CDC or SSCA
cannot generate native HTTPRoutes because of an upstream helper collision.
If this combination is needed after a Harness upgrade, test it again or use a
chart that loads the newer `harness-common` implementation in the meantime.

## License, Attribution, and Disclaimer

Except where otherwise noted, the source and chart material in this
repository is licensed under the [Apache License 2.0](LICENSE). See
[`NOTICE`](NOTICE) for attribution details.

No Harness Platform chart or other Harness source code is distributed in this
repository or its Helm package. The separately downloaded compatibility target
and its pinned checksum are documented in [`UPSTREAM.md`](UPSTREAM.md).

This is an independent, community-maintained project. It is not affiliated
with, endorsed by, sponsored by, or supported by Harness Inc., Envoy Gateway,
the Cloud Native Computing Foundation, or the Cilium project. All product
names and trademarks belong to their respective owners.

The Apache-2.0 license applies to the source and chart material distributed by
this repository. It does not grant a Harness product license, subscription,
registry access, rights to container images or other software installed by
the charts, commercial support, or trademark rights. Review all applicable
vendor terms before use.

The software is provided **AS IS**, without warranties or conditions of any
kind. The warranty disclaimer and limitation of liability in Sections 7 and 8
of the Apache License 2.0 apply. Validate rendered resources and test them in
a non-production environment before deployment.

For contribution, security-reporting, and support expectations, see
[`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), and
[`SUPPORT.md`](SUPPORT.md).
