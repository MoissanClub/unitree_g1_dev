# Manual teleoperation release workflow

This folder implements **build → freeze → human trial → promote → demo acceptance**.
There is no scheduler. Run a build whenever you want, normally once per day.
The working demo selection changes only when an administrator promotes or rolls back.

| Account | Responsibility |
| --- | --- |
| `dwei` | Administrator: initialize storage, request builds, freeze, promote, roll back |
| `teleops-ci` | Unprivileged build worker and human-operated candidate trial |
| `demo` | Operate the approved release and perform its acceptance test |

`dwei` invokes the build command with sudo, but the manager executes the entire
download/install/build process as `teleops-ci` using `runuser`. Neither operator
account needs sudo membership. Only use trusted repository sources: builds execute
dependency code as the builder, which has robot device access for later trials.

## Files in this folder

- `deployment.py`: administrator/ operator CLI, state transitions, shared session
  lock, freeze, release integrity verification, promotion and rollback.
- `build_worker.sh`: fresh build at the permanent release path as `teleops-ci`.
- `prepare_runtime.sh`: create the versioned runtime configuration template using
  the supplied hardware profile, without opening devices.
- `patch_runtime.py`: redirect teleimager YAML and robot IK cache writes away from
  the frozen source tree. Stops if the expected source structure changes.
- `launch_release.sh`: run the selected frozen software with per-account camera
  settings, TLS certificates, caches, logs, and recordings.
- `tests/`: software-only tests; these never start a robot or camera service.

## Release layout

```text
/opt/teleops/
├── bin/                       # Administrator-owned manager and build worker
├── deployment.json            # Builder/demo account names
├── selection.json             # Candidate, current and previous release IDs
├── session.lock               # Shared across both accounts and admin operations
└── releases/<release-id>/
    ├── release.json           # Build status and frozen content digest
    ├── build.log
    └── payload/
        ├── launcher/          # Versioned unitree_g1_dev checkout
        ├── hardware.env       # This build's hardware profile snapshot
        ├── work/              # Miniforge, XR, ROS, SDK and BrainCo builds
        ├── runtime-template/  # Versioned settings for both operator accounts
        └── ...                # Git revisions, package/system inventories
```

The manager uses **one atomically replaced selection.json** instead of updating
multiple symlinks separately. Launch resolves one release ID while holding the
session lock; promotion and rollback use that same lock. The environment is built
at its final path and is never copied/relocated at promotion. This preserves Conda
prefixes and editable-install paths.

After freeze, all payload files are root-owned and read-only to the
`teleops-releases` group. The manager checks ownership, permissions, and a full
content digest before running, promoting, or rolling back. Hashing a large release
can take a while. External system/ROS library links are allowed; other external
links and hardlinks outside the release are rejected at freeze.

Each operator gets separate writable data:

```text
~/.local/state/teleops/<release-id>/
├── pc2_teleop.env
├── cam_config_server.yaml
├── cert.pem / key.pem
├── cache/
├── logs/
└── recordings/
```

Settings are copied from the same frozen template at each launch; changing a
runtime copy is not a persistent configuration update. To change release settings,
build/freeze/test a new candidate. Certificates are per-account, so the Quest may
need to trust the demo account's certificate after a candidate trial. Both accounts
use the same software and template, but account permissions/caches/certificates
are why the final demo acceptance test is still required.

## Before the first build

Publish the launcher/setup/deployment changes and the constraints file first:
the build clones the requested Git branch rather than using uncommitted local files.
The administrator-owned manager and worker installed in `/opt/teleops/bin` should
come from that same reviewed version. No accounts, installed services, or robot
processes are changed merely by adding this folder to the repository.

The existing system prerequisites from [../DEMO_ACCOUNT.md](../DEMO_ACCOUNT.md)
step 2 must already be installed. This workflow does not manage APT packages,
drivers, JetPack, or vendor camera services. System upgrades can break both the
current and previous release; inventories are recorded but system rollback is not
provided.

### Terminal A — dwei — /home/dwei

Create the builder account once. Skip either adduser command if the account exists:

```bash
cd /home/dwei
sudo adduser teleops-ci
# Only if demo does not exist yet:
sudo adduser demo
sudo usermod -aG video,dialout teleops-ci
sudo usermod -aG video,dialout demo
```

Initialize deployment storage using the reviewed checkout:

```bash
cd /home/dwei/unitree_g1_dev/pc2/vr_teleops/deployment
sudo python3 deployment.py init --builder teleops-ci --demo demo
```

Log both operator accounts out and back in to activate their new groups. Do not
rerun init to update scripts: it deliberately refuses to reset existing state.
For future reviewed orchestration updates, copy only the manager and build worker:

```bash
# Account dwei; same directory; after reviewing the update
sudo install -o root -g root -m 0755 deployment.py build_worker.sh /opt/teleops/bin/
```

## 1. Build — Terminal A, dwei — any directory

Choose a unique ID. The command refuses an existing release directory:

```bash
sudo python3 /opt/teleops/bin/deployment.py build 2026-09-25-001 \
  --hardware-profile /home/dwei/unitree_g1_dev/pc2/g1_pc2_hardware.env
```

This performs a fresh build as `teleops-ci`, using the MoissanClub XR fork and its
pinned submodules. It uses the public upstream teleimager URL while retaining the
pinned commit (Git fails if that commit cannot be fetched). It preserves the
MoissanClub televuer fork with the controller fixes. Missing submodule files,
dependency conflicts, patch drift, import errors, and native build/link errors
fail the build. Software-only checks use loopback and never launch hardware services.

Follow progress from another **dwei** terminal:

```bash
sudo tail -f /opt/teleops/releases/2026-09-25-001/build.log
```

You can select another launcher branch/tag with `--ref`, another launcher URL with
`--repo`, or an XR URL with `--xr-url`. The default launcher branch is `main`.
The current demo selection is unchanged. Failed builds remain for diagnosis;
retry with a new ID. There is no automatic deletion of releases.

## 2. Freeze — Terminal A, dwei — any directory

After a successful software build:

```bash
sudo python3 /opt/teleops/bin/deployment.py freeze 2026-09-25-001
```

This freezes the software and configuration template, computes its digest, and
selects it as the candidate. It does not mark it as human-tested or promote it.
Do not keep background builder processes writing into the release while freezing.

## 3. Human trial — Terminal B, teleops-ci — /home/teleops-ci

Open a new terminal as `dwei`, then switch to the builder/operator account:

```bash
sudo -iu teleops-ci
cd /home/teleops-ci
python3 /opt/teleops/bin/deployment.py run --candidate --dry-run
```

The preview resolves the candidate and checks frozen files but starts no services.
Stop any existing teleoperation session, prepare the robot safely, then run:

```bash
# Account teleops-ci — this starts REAL teleoperation
python3 /opt/teleops/bin/deployment.py run --candidate -- --hand
```

**This is the step where you put on the Quest and evaluate the real experience.**
Check camera streaming, Quest connection, arm/hand tracking, the controller
start/pause/quit actions, optional recording/audio you use, and clean shutdown.
All services must stop when you quit or press Ctrl+C. `--no-motion` is not a
guarantee that arms or hands cannot move.

The manager will not start concurrent candidate/demo sessions. It also refuses
existing legacy hand/camera/XR processes instead of terminating them. If vendor
camera services hold the device, resolve that as `dwei` following the existing
camera procedure, keeping `ota_pipe` running.

If the candidate fails your trial, **do not promote**. Keep operating the existing
demo release. Make the fix and build a new ID; never edit a frozen release.

## 4. Promote — Terminal A, dwei — any directory

After you have finished the candidate session and judged it successful:

```bash
sudo python3 /opt/teleops/bin/deployment.py promote 2026-09-25-001 --accept-tested
```

`--accept-tested` is your explicit attestation that the real trial passed; it is
not automatically inferred from the process exit code. The manager verifies the
frozen contents again, records the approving administrator/time, and atomically
selects the new current release while retaining the old one as previous.

## 5. Demo acceptance / normal use — Terminal C, demo — /home/demo

From another `dwei` terminal:

```bash
sudo -iu demo
cd /home/demo
python3 /opt/teleops/bin/deployment.py run --dry-run
```

Then, with the robot prepared, run a short supervised acceptance test:

```bash
# Account demo — this starts REAL teleoperation
python3 /opt/teleops/bin/deployment.py run -- --hand
```

Use this same command for normal operation. Do not use the old
`/home/demo/unitree_g1_dev/.../demo.sh` for managed releases: it bypasses release
selection and the cross-account session lock. No user startup files or existing
demo configuration are overwritten by this workflow.

## Rollback — Terminal A, dwei — any directory

Stop the demo session first, then:

```bash
sudo python3 /opt/teleops/bin/deployment.py rollback
python3 /opt/teleops/bin/deployment.py status
```

Start a new session as demo using the normal managed run command. Rollback
selects the previous software and template together without rebuilding. On the
first-ever promotion there is no previous managed release; the old standalone
demo installation remains available through its original launcher.

## Local validation (no hardware)

From `dwei`, in this folder:

```bash
python3 -B -m unittest discover -s tests -v
python3 deployment.py --help
```

The lifecycle and runtime path tests are software-only. A full fresh release
installation, freeze under root, and real Quest/robot trials still require
on-device validation. No timer is installed by these scripts.
