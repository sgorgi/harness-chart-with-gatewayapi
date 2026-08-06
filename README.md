# Harness Gateway API transition

This directory contains a temporary and removable Gateway API implementation for Harness releases that still create Kubernetes `Ingress` resources.

The implementation intentionally does not read Harness subchart values. Instead, it renders the upstream Harness chart and derives the required routing information from the resulting Kubernetes `Ingress` and `Service` objects.

When Harness provides a suitable native Gateway API implementation, this entire directory and its separate Helm release can be removed.

## Design goals

- Keep `charts/` reserved for the unpacked upstream Harness chart.
- Keep all temporary Gateway API code in one removable directory.
- Support different `nonprod` and `prod` Harness values.
- Avoid coupling to Harness subchart names, templates, helpers, or internal values.
- Keep the existing Ingress resources active during the transition.
- Fail explicitly when an Ingress cannot be converted without changing its semantics.

## Repository layout

A typical repository layout is:

```text
.
├── charts/
│   └── harness/
│       └── Chart.yaml
├── configuration/
│   └── harness/
│       ├── common.yaml
│       ├── nonprod.yaml
│       └── prod.yaml
└── gateway-api/
    ├── Chart.yaml
    ├── README.md
    ├── render.sh
    ├── values.yaml
    ├── values.schema.json
    ├── environments/
    │   ├── nonprod.yaml
    │   └── prod.yaml
    ├── generated/
    └── templates/
        ├── _helpers.tpl
        ├── httproutes.yaml
        ├── listenerset.yaml
        └── referencegrants.yaml
```

The `gateway-api/` directory is a standalone Helm chart. It is deliberately not placed below `charts/`, because `charts/` remains reserved for the upstream Harness chart and its dependencies.

Harness values files do not need to be located beside the script or below the repository root. Pass each file explicitly with `-f` or `--values`. Relative paths are resolved from the directory where the script is executed. Absolute paths are also supported.

Values files use normal Helm precedence. The first file provides the lowest precedence, and every later file may override values from earlier files.

## What is generated

For every hostname found in the rendered Harness Ingress resources, the transition chart creates:

- one HTTPS listener in a `ListenerSet`
- one `HTTPRoute` per source Ingress and hostname
- one restricted `ReferenceGrant` per TLS Secret

The existing Harness Ingress resources are not changed or removed. This is the shadow mode behavior.

## Namespace model

The default configuration uses:

| Resource | Namespace |
|---|---|
| Parent `Gateway` | `envoy-gateway-apps` |
| `ListenerSet` | `envoy-gateway-apps` |
| `HTTPRoute` | Harness namespace discovered from the Ingress |
| TLS `Secret` | Harness namespace discovered from the Ingress |
| `ReferenceGrant` | Same Harness namespace as the TLS Secret |

The TLS certificate reference is defined on the `ListenerSet`. Therefore, the `ReferenceGrant` authorizes the `ListenerSet` kind from `envoy-gateway-apps` to reference the named Secret in the Harness namespace.

Although Envoy ultimately reads the certificate, Gateway API authorization is based on the Kubernetes resource that contains `certificateRefs`. In this implementation that resource is the `ListenerSet`, not the parent `Gateway`.

## Prerequisites

The following commands are required:

- Helm 3
- Bash 4 or newer
- [mikefarah/yq](https://github.com/mikefarah/yq) version 4

The cluster must already contain:

- Gateway API CRDs with `ListenerSet` support
- Envoy Gateway with ListenerSet support
- a parent `Gateway` named `apps-gateway` in `envoy-gateway-apps`
- `spec.allowedListeners` on the parent Gateway configured to accept the ListenerSet

Example parent Gateway setting:

```yaml
spec:
  allowedListeners:
    namespaces:
      from: All
```

## Generate nonprod resources

Pass every Harness values file in the same order you would pass them to `helm template`:

```bash
./gateway-api/render.sh nonprod \
  --values ../shared/harness-common.yaml \
  --values /srv/config/harness/nonprod.yaml \
  --values ./developer-overrides.yaml
```

The paths do not need to be below `gateway-api/`. The final file has the highest precedence.

It creates:

```text
gateway-api/generated/nonprod/harness-rendered.yaml
gateway-api/generated/nonprod/discovered-values.yaml
gateway-api/generated/nonprod/ingress-annotations.yaml
gateway-api/generated/nonprod/gateway-api.yaml
```

## Generate prod resources

Use the production values chain:

```bash
./gateway-api/render.sh prod \
  -f /srv/config/harness/common.yaml \
  -f /srv/config/harness/region-eu.yaml \
  -f /srv/config/harness/prod.yaml
```

It creates the corresponding files below:

```text
gateway-api/generated/prod/
```

Hostnames, TLS Secret names, paths, backend Services, and backend ports are therefore derived separately for each environment.

## Script options

```text
Usage:
  ./gateway-api/render.sh <nonprod|prod> [options]

Harness values files:
  -f, --values FILE          May be repeated. Later files override earlier files.

Other options:
      --harness-chart PATH   Override the unpacked Harness chart location.
      --gateway-values FILE  Override the Gateway transition values file.
      --output-dir PATH      Override the generated output directory.
      --release NAME         Override the Helm release name used for rendering.
      --namespace NAME       Override the Harness namespace.
```

When no `-f` or `--values` option is supplied, the script retains its original compatibility behavior and attempts to use:

```text
<repository-root>/values-base.yaml
<repository-root>/values-<environment>.yaml
```

Explicit values arguments are recommended because they make the render inputs visible and work independently of repository layout.

## Inspect the result

Review the discovered model first:

```bash
cat gateway-api/generated/nonprod/discovered-values.yaml
```

Review the Ingress annotations that are not converted automatically:

```bash
cat gateway-api/generated/nonprod/ingress-annotations.yaml
```

Then inspect the final Gateway API resources:

```bash
cat gateway-api/generated/nonprod/gateway-api.yaml
```

Useful resource checks after deployment:

```bash
kubectl get listenerset -n envoy-gateway-apps
kubectl get httproute -n harness
kubectl get referencegrant -n harness
```

Inspect status conditions:

```bash
kubectl describe listenerset harness -n envoy-gateway-apps
kubectl describe httproute -n harness
```

## Deploy as a separate Helm release

Generate the environment-specific discovered values first:

```bash
./gateway-api/render.sh nonprod \
  -f /srv/config/harness/common.yaml \
  -f /srv/config/harness/nonprod.yaml
```

Then install or upgrade the transition chart:

```bash
helm upgrade --install harness-gateway-transition ./gateway-api \
  --namespace harness \
  --values ./gateway-api/environments/nonprod.yaml \
  --values ./gateway-api/generated/nonprod/discovered-values.yaml
```

The Helm release namespace may be `harness`, while the rendered resources explicitly target both the Harness namespace and `envoy-gateway-apps`.

The identity running Helm must have permission to manage resources in both namespaces.

## GitOps usage

Flux does not execute this repository-specific discovery script as part of normal Helm rendering. Use one of these approaches:

1. Generate `discovered-values.yaml` in CI and commit it before Flux reconciles the transition Helm release.
2. Generate and validate the final manifests in CI, then deploy those manifests through a separate GitOps path.

For a temporary transition chart, committing the generated discovered values is usually the simpler option. CI should rerun the script after every Harness chart or values update and fail when the committed file changes unexpectedly.

Do not treat `harness-rendered.yaml` as a source file. It is only diagnostic output and can be excluded from Git.

## Shadow mode testing

The transition chart does not modify DNS and does not remove the existing Ingress resources.

Test Envoy directly before changing DNS:

```bash
curl --resolve harness.example.com:443:<ENVOY_IP> \
  https://harness.example.com/
```

Repeat the test for every generated hostname, including the Looker hostname when enabled.

## Supported Ingress features

The generator supports:

- `networking.k8s.io/v1` Ingress resources
- host-based routing
- `Prefix` paths
- `Exact` paths
- numeric backend Service ports
- named backend Service ports, resolved from rendered Service objects
- TLS Secrets explicitly associated with each hostname

The generator intentionally fails for:

- `ImplementationSpecific` paths
- rules without hostnames
- hosts without an explicitly matching TLS entry
- non-Service backends
- missing or unresolved backend ports

Failing is intentional. Silently converting unsupported behavior could produce a reachable route with different routing semantics.

## Ingress annotations

The script does not translate controller-specific Ingress annotations.

Before switching traffic, compare any behavior-affecting annotations with the resulting Envoy Gateway configuration. Typical examples include:

- request or response size limits
- backend protocol selection
- timeouts
- redirects
- rewrites
- authentication
- custom NGINX snippets

These features should be implemented explicitly with Gateway API fields or Envoy Gateway policies rather than copied automatically.

## Environment-specific Gateway settings

Most environment differences are discovered automatically from the rendered Harness manifests.

Use these files only for Gateway infrastructure differences:

```text
gateway-api/environments/nonprod.yaml
gateway-api/environments/prod.yaml
```

For example:

```yaml
gatewayTransition:
  gateway:
    name: apps-gateway
    namespace: envoy-gateway-apps
  listenerSet:
    name: harness
    namespace: envoy-gateway-apps
```

## Upgrade workflow

For every Harness chart or values update:

1. Run the generator for `nonprod` and `prod` with the exact values-file chain used by each Harness release.
2. Review changes in `discovered-values.yaml`.
3. Review the final `gateway-api.yaml` output.
4. Verify ListenerSet and HTTPRoute status in a nonprod cluster.
5. Test all hostnames directly against the Envoy address.
6. Promote the same process to prod.

A change in generated hostnames, paths, Services, ports, or TLS Secrets should be treated as an application routing change, even when the Harness chart upgrade documentation does not mention Gateway API.

## Removal when Harness supports Gateway API

When Harness provides the required native resources:

1. Render and test the native Harness Gateway API implementation in parallel.
2. Compare its routes, listeners, TLS references, and policies with this transition implementation.
3. Disable or uninstall the `harness-gateway-transition` Helm release.
4. Delete the `gateway-api/` directory.

No files below `charts/harness` need to be modified or restored.
