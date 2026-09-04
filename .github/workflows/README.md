# Release process

Versioning is **manual annotated tags**, `vMAJOR.MINOR.PATCH`.

Deliberately NOT release-please or semantic-release. Reasoning:

- Both tools derive a version from commit messages. That works when the version
  describes a **published API**. This repo publishes no API — a "release" here
  is "a combination of a compose file, a Dockerfile and scripts that was tested
  together on a droplet." Only a human knows whether that combination is good.
- The most disruptive changes in this repo are usually `chore:` or `fix:` by
  Conventional Commit rules and would ship as a patch: a Paseo base-image bump,
  a new required `.env` key, a volume layout change. Conventional Commits
  systematically under-version infra repos.
- Both tools want to own a version file and open a release PR on every merge.
  That is a lot of moving parts for a repo that ships when the maintainer has
  actually run `make doctor` on a real host.

What the numbers mean here (users read them as an upgrade risk signal):

| bump  | meaning                                                                   |
|-------|---------------------------------------------------------------------------|
| MAJOR | Upgrading loses state or needs manual work: volume layout change, renamed volume, removed `make` target, dropped service. |
| MINOR | New capability, or a NEW REQUIRED `.env` key. Anything that makes an existing `.env` incomplete is minor, never patch. |
| PATCH | Bug fixes, doc changes, pinned-version bumps. An existing `.env` keeps working untouched. |

Pre-1.0, treat MINOR as the breaking-change slot; the `:MAJOR` floating image
tag is deliberately not published for `v0.x` (see `release-image.yml`).

## Cutting a release

```bash
# 1. verify on a real host, not just in CI
make up && make doctor

# 2. tag
git tag -a v0.3.0 -m "v0.3.0"
git push origin v0.3.0
```

The tag fans out to two independent workflows:

- `release-image.yml` — builds `linux/amd64` + `linux/arm64` on native runners,
  pushes to `ghcr.io/itsjustanks/paseo-dev-stack`, attaches build provenance.
- `release.yml` — creates the GitHub Release with generated notes.

They are separate on purpose: a registry hiccup should not eat the release
notes, and vice versa. Re-run either alone from the Actions tab.

## One-time setup — make the GHCR package PUBLIC

A new GHCR package is **private by default**. `docker pull` then fails for
everyone with `denied`/`unauthorized`, which reads like a broken image.

There is no API or workflow flag for this on a personal account. After the first
successful `release-image` run:

1. https://github.com/users/itsjustanks/packages/container/paseo-dev-stack/settings
2. Danger Zone → **Change visibility** → **Public** → type the package name.
3. On the same page, **Connect repository** → `paseo-dev-stack`, so the package
   page shows the README. (The `org.opencontainers.image.source` label the
   workflow sets already points here, which is what makes that link offered.)

This is once per package, not per release. **Public is irreversible.**

Verify from a machine with no GitHub credentials:

```bash
docker run --rm quay.io/skopeo/stable inspect \
  docker://ghcr.io/itsjustanks/paseo-dev-stack:latest >/dev/null && echo public
```
