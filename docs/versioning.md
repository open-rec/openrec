# Distribution versioning

OpenRec uses semantic versioning for the complete distribution. Component repositories may version
independently; the distribution manifest is the authoritative compatibility set.

## Version meaning

- **Major:** incompatible recommendation API, event envelope, storage schema, graph, artifact, or
  operator contract change.
- **Minor:** backward-compatible capability, component, algorithm, or deployment addition.
- **Patch:** backward-compatible defect, security, documentation, or packaging correction.
- `-dev`, `-alpha`, `-beta`, and `-rc` releases do not carry stable compatibility guarantees.

## Manifest rules

Development manifests may use a branch ref to integrate current component work. Release candidates
and stable releases must use a component version tag or a full 40-character commit SHA. Every
manifest change must pass quality and relevant end-to-end workflows.

The manifest schema is versioned independently. Consumers must reject a newer schema they do not
understand instead of guessing.

## Compatibility policy

Within one major distribution line:

- recommendation clients remain backward compatible;
- Kafka consumers accept the previous envelope version during a documented migration window;
- storage and artifact changes include upgrade and rollback instructions;
- configuration removal requires prior deprecation;
- a release is not supported with arbitrary component substitutions unless separately tested.

Before `v1.0.0`, compatibility may change between minor releases, but every breaking change must be
called out in release notes with migration and rollback guidance.
