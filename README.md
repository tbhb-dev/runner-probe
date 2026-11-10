# Hosted runner probe matrix

A one-shot GitHub Actions workflow that records what GitHub-hosted runners provide for sandboxing. It is a draft: nothing here has been run or published.

## Use

Put the files in a public scratch repository and start the workflow by hand (`workflow_dispatch`). It has `permissions: contents: read`, uses no secrets and has no `pull_request_target` trigger. Each leg uploads `probe-<leg>.json` as an artifact.

## Legs

| Leg | Runner | Notes |
| --- | --- | --- |
| `ubuntu-24.04-x64-no-udev` | ubuntu-24.04 | `/dev/kvm` probed as shipped |
| `ubuntu-24.04-x64-udev` | ubuntu-24.04 | documented udev KVM-enable rule applied first |
| `ubuntu-24.04-arm` | ubuntu-24.04-arm | |
| `macos-15` | macos-15 | |
| `windows-2025` | windows-2025 | |

## What each leg records

- Linux: `kernel.apparmor_restrict_unprivileged_userns` and `kernel.unprivileged_userns_clone`; whether bwrap is preinstalled (installed by the probe if missing, and the record says so); `bwrap --unshare-user true` before changes, after setting the sysctl to 0, and after loading an AppArmor profile that grants `userns` to bwrap; Landlock ABI via the `landlock_create_ruleset` version syscall; `/dev/kvm` presence and access; `docker info`.
- macOS: `sandbox-exec` with a deny-file-read profile, compared against an unsandboxed read; `docker info`.
- Windows: AppContainer profile creation, job-object nesting (assigning a child to a new job), `docker info` including OS type and isolation.

Docker's Windows-containers mode is recorded as found. The workflow does not switch modes.

## Failure reporting

Every probe is its own step with `continue-on-error: true`. A probe script writes its JSON first and then exits non-zero if the capability is missing, so the failing step shows the failure and the run continues. The merge and upload steps run with `always()`.

## Placeholders

- `actions/checkout` and `actions/upload-artifact` are pinned to full SHAs written from memory, each with a version comment and a `PIN-ME` note. Check each SHA against the release before the first run.
