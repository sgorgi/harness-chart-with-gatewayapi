## Summary

Describe the problem and the implemented change.

## Validation

List the commands and relevant environments used to validate the change.

## Checklist

- [ ] `./scripts/test` passes.
- [ ] `helm lint . --strict` passes.
- [ ] Shell and Ruby static checks pass where applicable.
- [ ] No Harness chart archive or extracted `platform/` directory is included.
- [ ] Values files contain only switches introduced by this overlay.
- [ ] Documentation, comments, and user-facing messages are in English.
- [ ] No secrets, private domains, customer identifiers, or production values are included.
- [ ] License and attribution files remain intact.
