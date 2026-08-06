# company-harness Gateway API generator

This package implements a repository-local Gateway API transition for the
`company-harness` umbrella chart.

It does not create a separate Helm chart and it does not inspect Harness chart
internals. Instead, it renders the complete umbrella chart with the values used
by each environment, discovers the active Kubernetes `Ingress` and `Service`
objects, and generates deterministic Helm templates below `templates/`.

The existing Ingress resources remain active. This provides shadow mode until
the generated Gateway API resources have been validated and traffic is moved.

## Expected repository layout

```text
company-harness/
├── Chart.yaml
├── values-base.yaml
├── values-prod.yaml
├── values-ut.yaml
├── charts/
│   └── harness/
│       └── Chart.yaml
├── templates/
└── scripts/
    └── generate_gateway_api.sh
```

Copy `scripts/generate_gateway_api.sh` into the repository and merge the
supplied values snippets into the existing values files.

## Requirements

The generator is intended for Linux and requires:

* Bash 4 or newer
* Helm 3
* mikefarah/yq v4
* GNU `sha256sum`, `install`, `cmp`, `diff`, `sed` and `sort`

Python and `jq` are not required.

## Values configuration

Merge the supplied snippets into:

```text
values-base.yaml
values-ut.yaml
values-prod.yaml
```

The base configuration keeps the parent `Gateway` and generated `ListenerSet`
in `envoy-gateway-apps`. Generated `HTTPRoute` objects and TLS Secrets remain in
the Harness release namespace.

Because the ListenerSet references TLS Secrets in another namespace, the
generator also creates a restricted `ReferenceGrant` in the Harness namespace.
Only the discovered Secret names are authorized.

## Generate both environments

Run from `company-harness/`:

```bash
./scripts/generate_gateway_api.sh all \
  --release harness \
  --namespace harness
```

The release name and namespace must match the real Helm release. They can affect
rendered resource names and namespaces.

The script performs renders equivalent to:

```bash
helm template harness . \
  --namespace harness \
  --values values-base.yaml \
  --values values-ut.yaml \
  --set gatewayAPI.enabled=false

helm template harness . \
  --namespace harness \
  --values values-base.yaml \
  --values values-prod.yaml \
  --set gatewayAPI.enabled=false
```

`gatewayAPI.enabled=false` prevents previously generated Gateway API templates
from taking part in discovery. It does not disable the upstream Harness Ingress
resources.

## Generated files

The committed outputs are:

```text
templates/generated-gateway-api-ut.yaml
templates/generated-gateway-api-prod.yaml
```

Diagnostic outputs are also written:

```text
.generated/gateway-api/ut/active-ingresses.yaml
.generated/gateway-api/ut/active-services.yaml
.generated/gateway-api/ut/ingress-annotations.json

.generated/gateway-api/prod/active-ingresses.yaml
.generated/gateway-api/prod/active-services.yaml
.generated/gateway-api/prod/ingress-annotations.json
```

Both generated files remain below `templates/`, but each is guarded by
`gatewayAPI.environment`. A UT release therefore renders only the UT resources,
and a production release renders only the production resources.

## Generated resources

For each environment, the generator creates:

* one `ListenerSet`
* one HTTPS listener per discovered TLS hostname
* one `HTTPRoute` per source Ingress and hostname
* one restricted `ReferenceGrant` containing the discovered TLS Secret names
* optional port 80 listeners and HTTP to HTTPS redirect routes

The mapping is derived from the rendered Kubernetes objects:

| Ingress property | Generated property |
|---|---|
| Rule hostname | Listener and HTTPRoute hostname |
| TLS Secret | ListenerSet `certificateRefs` |
| `Prefix` path | HTTPRoute `PathPrefix` |
| `Exact` path | HTTPRoute `Exact` |
| Backend Service | HTTPRoute `backendRefs.name` |
| Numeric Service port | HTTPRoute `backendRefs.port` |
| Named Service port | Resolved from the rendered Service |

## Cross-namespace model

The default values create this relationship:

| Resource | Namespace |
|---|---|
| Parent Gateway | `envoy-gateway-apps` |
| ListenerSet | `envoy-gateway-apps` |
| HTTPRoutes | Harness release namespace |
| TLS Secrets | Harness release namespace |
| ReferenceGrant | Harness release namespace |

The ListenerSet uses an explicit Secret namespace:

```yaml
certificateRefs:
  - group: ""
    kind: Secret
    name: discovered-secret-name
    namespace: harness
```

The generated `ReferenceGrant` allows the ListenerSet namespace to reference
only the listed Secret names.

The parent Gateway must permit ListenerSets according to your existing Gateway
configuration. The ListenerSet permits HTTPRoutes from all namespaces so that
routes in the Harness namespace can attach to it.

## Named Service ports

An Ingress can use a named backend port:

```yaml
backend:
  service:
    name: harness-manager
    port:
      name: http
```

Gateway API requires a numeric backend port. The generator resolves `http`
against the `Service` objects from the same umbrella-chart render and writes the
result:

```yaml
backendRefs:
  - name: harness-manager
    port: 9090
```

Generation fails when the named port cannot be resolved uniquely.

## Intentional validation failures

The generator fails rather than silently changing routing behavior when it
finds:

* an Ingress rule without a hostname
* a hostname without an explicitly matching TLS Secret
* `ImplementationSpecific` or missing path types
* a non-Service backend
* a missing or unresolved Service port
* conflicting TLS Secrets for the same hostname
* an Ingress outside the Helm release namespace

These failures indicate that the source Ingress cannot be translated safely by
the generic generator.

## Ingress annotations

Controller-specific annotations are not automatically translated. Examples
include:

```text
nginx.ingress.kubernetes.io/rewrite-target
nginx.ingress.kubernetes.io/proxy-read-timeout
nginx.ingress.kubernetes.io/proxy-body-size
nginx.ingress.kubernetes.io/backend-protocol
```

Rewrites, timeouts, authentication, body limits, backend protocols and similar
behavior may require HTTPRoute filters or Envoy Gateway policies.

The generator:

* records these annotations in
  `.generated/gateway-api/<environment>/ingress-annotations.json`
* embeds them as comments in the generated template
* includes annotation value changes in generated-file diffs

After every relevant annotation has been handled explicitly, enable strict CI
validation:

```bash
./scripts/generate_gateway_api.sh all \
  --release harness \
  --namespace harness \
  --check \
  --strict-annotations
```

## Upgrade and GitOps workflow

Commit the two generated templates below `templates/`.

Rerun generation after every change to:

* `charts/harness`
* `Chart.yaml`
* `values-base.yaml`
* `values-ut.yaml`
* `values-prod.yaml`
* custom templates that can affect Ingress or Service output

Generate and review changes:

```bash
./scripts/generate_gateway_api.sh all \
  --release harness \
  --namespace harness

git diff -- templates/generated-gateway-api-ut.yaml \
  templates/generated-gateway-api-prod.yaml
```

CI should verify that the committed output is current:

```bash
./scripts/generate_gateway_api.sh all \
  --release harness \
  --namespace harness \
  --check
```

`--check` does not modify files. It prints a unified diff and exits with status
1 when the committed templates no longer match the active Ingress model.

This pre-generation step is required because one Helm template cannot inspect
the already rendered manifests of a dependency during the same Helm render.

## Final umbrella-chart render

Render UT after generation:

```bash
helm template harness . \
  --namespace harness \
  --values values-base.yaml \
  --values values-ut.yaml \
  > rendered-ut.yaml
```

Inspect only the generated transition resources:

```bash
yq eval 'select(
  .kind == "ListenerSet" or
  .kind == "HTTPRoute" or
  .kind == "ReferenceGrant"
)' rendered-ut.yaml
```

Validate against a cluster containing the required CRDs:

```bash
kubectl apply --server-side --dry-run=server -f rendered-ut.yaml
```

## Shadow-mode validation

Keep the existing Ingress resources enabled while testing.

After deployment:

```bash
kubectl get listenerset -n envoy-gateway-apps
kubectl get httproute -n harness
kubectl get referencegrant -n harness

kubectl describe listenerset harness -n envoy-gateway-apps
kubectl get httproute -n harness -o yaml
```

Test each hostname directly against the Envoy address before changing DNS:

```bash
curl --resolve harness.example.com:443:ENVOY_IP \
  https://harness.example.com/
```

Do not disable the old Ingress resources until:

* ListenerSet and HTTPRoute status conditions are accepted
* TLS certificate references are resolved
* controller-specific behavior has been reproduced
* direct traffic tests pass for every hostname and important path

## Network policies

The generator intentionally does not create a `CiliumNetworkPolicy`. Ingress
objects describe host and Service routing, but they do not fully describe the
destination Pod selectors, resolved endpoint target ports, or legitimate
east-west callers needed for a safe network policy.

Keep the Cilium policy as an explicit custom template and values model. Do not
derive it solely from the generated HTTPRoute backend list.

## Makefile integration

The package includes `Makefile.gateway-api`. Either include its targets in your
existing Makefile or copy the targets directly.

```bash
make -f Makefile.gateway-api gateway-api-generate
make -f Makefile.gateway-api gateway-api-check
make -f Makefile.gateway-api gateway-api-check-strict
```

## Removal

When Harness provides a suitable native Gateway API implementation:

1. Render and test the native resources in parallel.
2. Compare routes, listeners, TLS references and policies.
3. Remove the generated templates and generator script.
4. Remove the `gatewayAPI` values blocks.

No file below `charts/harness` is modified by this implementation.
