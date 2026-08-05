# External Compatibility Target

This repository does not vendor or redistribute the Harness Platform Helm
chart. The chart is an external compatibility target used only by the render
contract tests and by Harness installations managed separately from this
overlay.

The default test command downloads the following official release into a
temporary directory, verifies its archive checksum, runs the tests, and
removes it again:

- Project: [Harness Helm Charts](https://github.com/harness/helm-charts)
- Release: [`platform-0.42.1`](https://github.com/harness/helm-charts/releases/tag/platform-0.42.1)
- Upstream commit: `1a4b7c959ff27688902303b5e9ea7bafc2dbef2b`
- Release archive SHA-256:
  `cc793123b6c8658fe28bbdd3d1b1b7f44dcc350cbbe91fbbf1ad92e9ecaa0250`
- Upstream license:
  [Apache-2.0](https://github.com/harness/helm-charts/blob/platform-0.42.1/LICENSE.md)

The archive URL and checksum are pinned in `scripts/fetch-platform-chart`.
Downloaded upstream content is not part of this project's source or Helm
package and remains subject to its own license and vendor terms.

## Updating the Compatibility Target

Use a dedicated pull request for a new Harness Platform chart version:

1. Select an official Harness release and verify its published provenance.
2. Update the version, archive URL, and SHA-256 in
   `scripts/fetch-platform-chart`.
3. Update the release, commit, and checksum in this file and the tested
   version annotation in `Chart.yaml`.
4. Review all Ingress conversion and generated-inventory assumptions.
5. Run the complete contract suite with both supported Helm major versions.

Do not commit the downloaded chart, its extracted `platform/` directory, or
the release archive to this repository.
