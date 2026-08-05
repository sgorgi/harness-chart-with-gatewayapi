# Contributing

Contributions are welcome. By submitting a contribution, you agree that it is
licensed under the Apache License 2.0 in this repository.

## Development Requirements

- Bash
- Helm 3.19 or 4.2
- ShellCheck for local shell validation
- `curl` and either `sha256sum` or `shasum` for the pinned upstream test

## Before Opening a Pull Request

Run the complete contract suite and the static checks:

```sh
bash ./scripts/test
helm lint . --strict
shellcheck -s bash scripts/test scripts/fetch-platform-chart \
  scripts/generate-gateway-api tests/render_contract_test.sh
```

Please also confirm that:

- No Harness chart archive or extracted `platform/` directory is committed.
- `values.yaml` and `values-base.yaml` contain only values introduced by this
  overlay.
- Generated environment inventories are reproducible and are not committed.
- Documentation, comments, commit messages, and user-facing errors are in
  English.
- Tests cover changed rendering behavior and compatibility assumptions.
- Logs, rendered manifests, and examples contain no credentials, private
  domains, customer identifiers, or production values.
- License information remains intact.
- An upstream compatibility update changes only the pinned external version,
  checksum, documentation, and compatibility implementation.

## Reporting Problems

Use the GitHub issue forms for reproducible bugs and feature proposals. For a
security vulnerability, follow [`SECURITY.md`](SECURITY.md) and do not disclose
sensitive details in a public issue.

Issues in Harness Platform itself should be reported to the
[Harness Helm Charts project](https://github.com/harness/helm-charts) or through
the support channel associated with the relevant Harness subscription.
