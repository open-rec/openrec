# Releasing OpenRec

## Release candidate

1. Choose a semantic distribution version and remove the development suffix from `VERSION`.
2. Tag or resolve every component to an immutable full commit SHA.
3. Update `release/openrec.json` with the same distribution version and immutable refs.
4. Update user documentation, compatibility notes, migrations, and rollback instructions.
5. Run the quality workflow, standalone E2E, and cluster E2E against the exact manifest.
6. Confirm image digests, dependency scans, licenses, and sample credentials.

## Publish

Create an annotated tag matching `VERSION`:

```shell
git switch release/0.1.0
git tag -a v0.1.0 -m 'OpenRec v0.1.0'
git push origin v0.1.0
```

The release workflow revalidates version consistency, rejects floating component refs, assembles the
distribution bundle, writes SHA-256 checksums, and creates a GitHub Release. Each component also publishes its reviewed `RELEASE_NOTES.md`, source archive and checksums.
Version 0.1.0 is a source release: Maven Central, PyPI and versioned OCI image publication are not
part of this workflow. If publishing images separately, record their immutable digests.

## After publication

- Run a clean install from the published archive on a machine without local component checkouts.
- Verify documentation links and release assets.
- Announce supported upgrade paths and known limitations.
- Keep the previous compatible distribution available for rollback.
- Advance `VERSION` and the manifest to the next development version.
