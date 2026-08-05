# Pull Request

## Summary

Describe the problem and the implemented change.

## Validation

List the commands and relevant environments used to validate the change.

## Checklist

- [ ] `bash ./scripts/test` passes.
- [ ] `helm lint . --strict` passes.
- [ ] Shell static checks pass.
- [ ] No Harness chart archive or extracted `platform/` directory is included.
- [ ] No generated environment chart or routing inventory is included.
- [ ] Values files contain only switches introduced by this overlay.
- [ ] Documentation, comments, and user-facing messages are in English.
- [ ] No secrets, private domains, customer identifiers, or production values
      are included.
- [ ] License and attribution files remain intact.
