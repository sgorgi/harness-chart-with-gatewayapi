# Public Repository Checklist

The repository files are ready for publication. Complete the GitHub-specific
items below after the final repository URL and owner are known.

## Before the First Push

- Create an empty public GitHub repository without generated README, license,
  or `.gitignore` files.
- Use `main` as the default branch.
- Review the staged file list and confirm that `.DS_Store`, local values,
  kubeconfigs, certificates, keys, and packaged charts are absent.
- Run `bash ./scripts/test`, `helm lint . --strict`, and the static checks from
  `CONTRIBUTING.md`.
- Confirm that no `platform/` directory or Harness chart archive is staged.
- Confirm that no generated environment chart or routing inventory is staged.
- Set a concise repository description and topics such as `helm`,
  `gateway-api`, `envoy-gateway`, and `harness`.

## Repository Metadata

- Confirm the public URL in `Chart.yaml` remains correct.
- Add a CI badge to `README.md` if desired.
- Add maintainer metadata only when a public contact address is available.
- Update links if the repository is transferred or renamed.

## Recommended GitHub Settings

- Enable private vulnerability reporting.
- Enable the dependency graph, Dependabot alerts, secret scanning, and push
  protection where available.
- Protect `main` and require the Helm 3 and Helm 4 CI jobs before merging.
- Require pull request review for changes to `LICENSE`, `NOTICE`, `UPSTREAM.md`,
  `scripts/fetch-platform-chart`, and `.github/workflows/`.
- Keep the default `GITHUB_TOKEN` permissions read-only unless a future
  release workflow explicitly needs more access.
- Do not publish a Harness chart archive as a project release asset; link to
  the official Harness release.

## Releases

- Tag overlay releases independently from Harness Platform releases.
- Keep the tested Harness, Envoy Gateway, and Gateway API versions in
  `Chart.yaml` annotations current.
- Include `LICENSE`, `NOTICE`, and the packaged overlay in every release.
- Consider signing chart packages and publishing provenance before listing
  the chart in Artifact Hub.
