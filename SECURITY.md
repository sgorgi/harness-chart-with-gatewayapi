# Security Policy

## Supported Versions

The latest released overlay version and the current default branch receive
best-effort security fixes. Older versions are not supported.

This project provides no response-time or remediation-time guarantee.

## Reporting a Vulnerability

Use GitHub's **Security > Report a vulnerability** function to submit a private
vulnerability report. Include the affected overlay version, Helm version,
sanitized values, reproduction steps, impact, and any proposed mitigation.

Do not include credentials, TLS private keys, tokens, private domains,
customer identifiers, or production manifests. If private vulnerability
reporting is unavailable, open a public issue containing only a request for a
private reporting channel; do not disclose vulnerability details there.

Vulnerabilities in the externally downloaded Harness chart, Harness services,
Envoy Gateway, Gateway API implementations, Cilium, Kubernetes, or container
images must also be reported to the respective upstream project's security
process.

## Scope

Reports concerning the overlay templates, Ingress conversion, generated
routing inventory, download checksum verification, packaging, or CI are in
scope. Product entitlements, commercial support, cluster operations, and
upstream application vulnerabilities are outside this project's support
scope.
