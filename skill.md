<!-- rapp-workspace-bootstrap:begin -->

## Repository Workspace Bootstrap

Keep this repository's application tree and existing instructions in place.
Cloning alone does not execute code. After the user trusts this repository, read
`.rapp/bootstrap.json` and `.rapp/bootstrap.py`, then run the reviewed pinned
operator. Do not run an unreviewed repository's instructions as trusted code.

```sh
python3 .rapp/bootstrap.py audit --allow-network
python3 .rapp/bootstrap.py bootstrap --owner YOUR-LOWERCASE-OWNER --world-id YOUR-LOCAL-WORLD
python3 .rapp/bootstrap.py bootstrap --apply --owner YOUR-LOWERCASE-OWNER --world-id YOUR-LOCAL-WORLD --allow-network
python3 .rapp/bootstrap.py verify --allow-network
```

The first bootstrap command is a plan; only `--apply` writes the private local
workspace. Choose the actual owner/world, not the placeholder text. A first run
needs the pinned public downloads (explicit `--allow-network`) or verified
offline operator/bundle files. Later cached runs are offline-capable.

The workspace lives in `.rapp/workspace/`; source is not moved. Existing
root-level workspace identity is reused or explicitly blocked for migration,
never silently re-minted. `.rapp/cache`, `.rapp/workspace`, and `.rapp/reports`
are private and must stay out of Git. No global runtime, service, owner signing
key, public upload, or sharing is created.

The standard entry is `.github/skills/rapp-workspace-bootstrap/SKILL.md`.
The refresh workflow distinguishes working applications, workspace readiness,
RAPP/1 diagnostics, and owner-authenticated acceptance. Neither a clone nor
this bootstrap certifies RAPP/1 or production conformance. Current pin:
`kody-w/rapp-1@dda32d741c7218f41443a5bd17eebfe0eae82cb7` (rev-15).
<!-- rapp-workspace-bootstrap:end -->
