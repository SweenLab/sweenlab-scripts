# SweenLab repository working instructions

- The Debian LXC wizard is a single self-contained script. Preserve the one-command launch and the fully step-by-step interaction; do not introduce a Default/Advanced shortcut.
- Ask before changing existing behavior unless the user has explicitly requested that change. A requested tweak authorizes its implementation and publication within that scope.
- Every user-visible tweak or update must have a new version and a GitHub release recording the change, including documentation-only updates. Group changes made for one user request into one release; do not create releases for temporary fixes during development.
- For the Debian wizard, use immutable tags named `debian-lxc-vX.Y.Z`. Increase the patch version for fixes, wording changes, and documentation updates. Update SCRIPT_VERSION, the README, guide version labels, and CHANGELOG.md together.
- Keep release notes concrete: what changed, resulting behavior, launch command, validation performed, and remaining live-test limitations. Do not imply live Proxmox testing occurred when it did not.
- Keep the README and guide launch command pinned to the release's actual script commit so raw GitHub main-branch caching cannot serve an older script. Never move an existing release tag. Verify the command downloads the intended version before reporting completion.
- Publish the matching GitHub release after the authorized changes reach main. If publication fails, report that explicitly; a commit alone does not satisfy the release requirement.
- Preserve historical releases. The older maintenance tools were removed from main at the user's request; do not restore them.
