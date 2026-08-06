# company-harness Gateway API generator

This package generates Gateway API Helm templates from the Kubernetes `Ingress`
and `Service` objects rendered by the complete `company-harness` umbrella chart.

It does not inspect the internals of `charts/harness`. It runs `helm template`
with the values files supplied on the command line, discovers the active source
objects, and writes deterministic templates below `templates/`.

The existing Ingress resources remain active. This allows the generated Gateway
API resources to be tested in shadow mode before traffic is switched.

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

The values files do not need to use these names and do not need to be in the
chart directory. Every values file is supplied explicitly with `-f` or
`--values`.

## Requirements

The generator is intended for Linux and requires:

* Bash 4 or newer
* Helm 3
* mikefarah/yq v4
* GNU `sha256sum`, `install`, `cmp`, `diff`, `grep`, `sed` and `sort`

Python and `jq` are not required.

## Gateway API values

Only the Gateway API infrastructure settings need to be maintained manually.
Merge the supplied base snippet into an appropriate values file:

```yaml
gatewayAPI:
  enabled: false
  environment: ""

  gateway:
    name: apps-gateway
    namespace: envoy-gateway-apps

  listenerSet:
    name: harness
    namespace: envoy-gateway-apps

  referenceGrant:
    name: harness-gateway-tls

  httpRedirect:
    enabled: false
    statusCode: 301
```

Each release values chain must set the environment to the profile used when the
template was generated. For example:

```yaml
# UT values
gatewayAPI:
  environment: ut
  enabled: true
```

```yaml
# Production values
gatewayAPI:
  environment: prod
  enabled: true
```

The generator does not modify these values files.

## Values-file precedence

Pass the values files in the same order used for the real Helm release:

```bash
./scripts/generate_gateway_api.sh ut \
  -f values-base.yaml \
  -f values-ut.yaml
```

The long form is equivalent:

```bash
./scripts/generate_gateway_api.sh prod \
  --values /srv/harness/common.yaml \
  --values /srv/harness/region-eu.yaml \
  --values /srv/harness/prod.yaml
```

Later files have higher precedence, matching normal Helm behavior. Relative
values paths are resolved from the directory in which the script is executed.
Absolute paths are supported.

The script must be run once per profile. This is intentional because UT and
production can use different values chains and different precedence:

```bash
./scripts/generate_gateway_api.sh ut \
  -f values-base.yaml \
  -f values-ut.yaml

./scripts/generate_gateway_api.sh prod \
  -f values-base.yaml \
  -f values-prod.yaml
```

During discovery, the script appends:

```text
--set gatewayAPI.enabled=false
```

This prevents an existing generated template from participating in the source
render. It does not disable the upstream Harness Ingress resources. All supplied
values files otherwise retain their normal order and precedence.

## Command-line interface

```text
./scripts/generate_gateway_api.sh <profile> [options] [-f FILE ...]
```

Useful options:

```text
-f, --values FILE
--chart-dir PATH
--release NAME
--namespace NAME
--output-dir PATH
--diagnostics-dir PATH
--implementation-specific auto|regex|prefix|fail
--check
--strict-annotations
```

The profile is normally `ut` or `prod`, but any lowercase DNS-label-style name
can be used.

## Generated files

For profile `ut`, the committed output is:

```text
templates/generated-gateway-api-ut.yaml
```

For profile `prod`:

```text
templates/generated-gateway-api-prod.yaml
```

Diagnostic output is written below:

```text
.generated/gateway-api/<profile>/active-ingresses.yaml
.generated/gateway-api/<profile>/active-services.yaml
.generated/gateway-api/<profile>/ingress-annotations.json
.generated/gateway-api/<profile>/values-files.txt
```

Each generated template is guarded by:

```gotemplate
{{- if and
      (default false .Values.gatewayAPI.enabled)
      (eq (default "" .Values.gatewayAPI.environment) "ut")
}}
```

Both generated files can therefore remain under `templates/`. Only the file for
the selected environment is rendered by Helm.

## Generated resources

The generator creates:

* one `ListenerSet`
* one HTTPS listener per discovered TLS hostname
* one `HTTPRoute` per source Ingress and hostname
* one restricted `ReferenceGrant` for the discovered TLS Secrets
* `HTTPRouteFilter` resources for supported regex rewrites
* optional port 80 listeners and HTTP-to-HTTPS redirect routes

The mapping is derived from the rendered Kubernetes objects:

| Ingress property | Generated property |
|---|---|
| Rule hostname | Listener and HTTPRoute hostname |
| TLS Secret | ListenerSet `certificateRefs` |
| `Prefix` path | HTTPRoute `PathPrefix` |
| `Exact` path | HTTPRoute `Exact` |
| Regex path | HTTPRoute `RegularExpression` |
| Backend Service | HTTPRoute `backendRefs.name` |
| Numeric Service port | HTTPRoute `backendRefs.port` |
| Named Service port | Resolved from the rendered Service |
| Fixed rewrite target | Core `URLRewrite` with `ReplaceFullPath` |
| Capture-group rewrite | Envoy Gateway `HTTPRouteFilter` |

## Cross-namespace TLS model

The default values create this relationship:

| Resource | Namespace |
|---|---|
| Parent Gateway | `envoy-gateway-apps` |
| ListenerSet | `envoy-gateway-apps` |
| HTTPRoutes | Harness release namespace |
| TLS Secrets | Harness release namespace |
| ReferenceGrant | Harness release namespace |

The ListenerSet explicitly references each TLS Secret in the Harness namespace.
The generated `ReferenceGrant` authorizes only those discovered Secret names.

The parent Gateway must permit ListenerSets from the ListenerSet namespace. The
ListenerSet permits the generated HTTPRoutes from the Harness namespace.

## Named Service ports

An Ingress may reference a named Service port:

```yaml
backend:
  service:
    name: harness-manager
    port:
      name: http
```

Gateway API requires the Service port number. The generator resolves the name
against the Services from the same umbrella-chart render:

```yaml
backendRefs:
  - name: harness-manager
    port: 9090
```

Generation fails when the port cannot be resolved uniquely.

## ImplementationSpecific paths

Kubernetes deliberately leaves `ImplementationSpecific` path behavior to the
Ingress controller. It cannot always be translated safely without controller
context.

The default mode is:

```text
--implementation-specific auto
```

For ingress-nginx, the generator performs a host-wide pre-scan:

* `nginx.ingress.kubernetes.io/use-regex: "true"` enables regex mode.
* `nginx.ingress.kubernetes.io/rewrite-target` also enables regex mode.
* ingress-nginx applies that regex mode to all paths for the same hostname.
* an `ImplementationSpecific` path containing obvious regex characters is
  treated as a regex even when the annotation is absent.
* a literal `ImplementationSpecific` path is treated as `PathPrefix`.

Other modes are available:

| Mode | Behavior |
|---|---|
| `auto` | Infer regex behavior, otherwise use `PathPrefix` |
| `regex` | Treat every `ImplementationSpecific` path as regex |
| `prefix` | Use `PathPrefix` unless host-wide ingress-nginx regex mode is explicit |
| `fail` | Reject every `ImplementationSpecific` path |

### Example: Harness authz path

This Ingress path:

```yaml
path: /authz(/|$)(.*)
pathType: ImplementationSpecific
```

is generated as a case-insensitive RE2-compatible match:

```yaml
matches:
  - path:
      type: RegularExpression
      value: "(?i)^/authz(/|$)(.*)"
```

The `(?i)` flag preserves ingress-nginx case-insensitive regex behavior. The `^`
anchor preserves its start-of-path behavior.

## nginx rewrite-target conversion

The following common ingress-nginx combination is translated automatically:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - http:
        paths:
          - path: /authz(/|$)(.*)
            pathType: ImplementationSpecific
```

The generator creates an Envoy Gateway `HTTPRouteFilter` similar to:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: HTTPRouteFilter
spec:
  urlRewrite:
    path:
      type: ReplaceRegexMatch
      replaceRegexMatch:
        pattern: "(?i)^/authz(/|$)(.*)"
        substitution: "/\\2"
```

and references it from the matching HTTPRoute rule.

Numeric NGINX capture references such as `$1`, `$2` and `$3` are converted to
Envoy substitutions such as `\1`, `\2` and `\3`. Unsupported `$` expressions
cause generation to fail rather than produce a different route.

A rewrite target without capture references is translated to the core Gateway
API `URLRewrite` filter with `ReplaceFullPath`.

## Regex limitations

Ingress-nginx path expressions and Envoy Gateway regex features both use
RE2-compatible syntax in the supported migration path. Even so, regex route
precedence is implementation-specific in Gateway API, especially when multiple
HTTPRoutes for the same hostname contain overlapping regular expressions.

Review and test overlapping paths carefully. The generator orders paths by
source-path length within each generated HTTPRoute, matching ingress-nginx's
longer-path-first approach as closely as possible.

Do not disable the existing Ingress until the generated routes have an accepted
status and direct traffic tests confirm matching and rewrite behavior.

## Other Ingress annotations

The generator translates these ingress-nginx annotations:

```text
nginx.ingress.kubernetes.io/use-regex
nginx.ingress.kubernetes.io/rewrite-target
```

Other controller-specific annotations are not translated automatically.
Examples include:

```text
nginx.ingress.kubernetes.io/proxy-read-timeout
nginx.ingress.kubernetes.io/proxy-body-size
nginx.ingress.kubernetes.io/backend-protocol
nginx.ingress.kubernetes.io/auth-url
```

The diagnostic annotation report separates translated and untranslated values:

```json
{
  "access-control-services|example.company.ch": {
    "translated": {
      "nginx.ingress.kubernetes.io/use-regex": "true",
      "nginx.ingress.kubernetes.io/rewrite-target": "/$2"
    },
    "untranslated": {}
  }
}
```

Use strict validation after all remaining annotations have been migrated:

```bash
./scripts/generate_gateway_api.sh ut \
  -f values-base.yaml \
  -f values-ut.yaml \
  --check \
  --strict-annotations
```

Translated `use-regex` and `rewrite-target` annotations do not cause strict mode
to fail. Other controller-specific annotations do.

## Upgrade and GitOps workflow

Generate and commit one template per values chain:

```bash
./scripts/generate_gateway_api.sh ut \
  -f values-base.yaml \
  -f values-ut.yaml

git diff -- templates/generated-gateway-api-ut.yaml
```

After every relevant Harness chart or values change, CI should rerun the exact
same command with `--check`:

```bash
./scripts/generate_gateway_api.sh ut \
  -f values-base.yaml \
  -f values-ut.yaml \
  --check
```

`--check` does not modify the committed template. It prints a unified diff and
exits with status 1 when the active Ingress model no longer matches the generated
Gateway API template.

This pre-generation step is required because one Helm template cannot inspect
the already rendered manifests of a dependency during the same Helm render.

## Final umbrella-chart render

After generation, render the umbrella chart with the same values chain:

```bash
helm template harness . \
  --namespace harness \
  -f values-base.yaml \
  -f values-ut.yaml \
  > rendered-ut.yaml
```

Inspect the transition resources:

```bash
yq eval 'select(
  .kind == "ListenerSet" or
  .kind == "HTTPRoute" or
  .kind == "HTTPRouteFilter" or
  .kind == "ReferenceGrant"
)' rendered-ut.yaml
```

Validate against a cluster containing the Gateway API and Envoy Gateway CRDs:

```bash
kubectl apply --server-side --dry-run=server -f rendered-ut.yaml
```

After deployment:

```bash
kubectl get listenerset -n envoy-gateway-apps
kubectl get httproute,httproutefilter -n harness
kubectl get referencegrant -n harness
kubectl describe httproute -n harness
```

## Shadow-mode traffic test

Keep the existing Ingress resources enabled. Test Envoy directly before changing
DNS:

```bash
curl --resolve harness.example.com:443:<ENVOY_IP> \
  https://harness.example.com/
```

For the regex example, test all relevant shapes:

```bash
curl --resolve example.company.ch:443:<ENVOY_IP> \
  https://example.company.ch/authz

curl --resolve example.company.ch:443:<ENVOY_IP> \
  https://example.company.ch/authz/

curl --resolve example.company.ch:443:<ENVOY_IP> \
  https://example.company.ch/authz/example
```
