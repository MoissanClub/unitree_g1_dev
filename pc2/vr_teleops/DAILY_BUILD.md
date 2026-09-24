# Daily demo installation check

For the newer **manual build → human trial → promotion** workflow, use
[deployment/README.md](deployment/README.md). This page describes the earlier
software-only reporting tool; its optional timer is not needed for deployment.

This is a report-only build of a fresh demo-style environment on PC2. A separate
`teleop-ci` account builds the software each day; the working `demo` account is
never reset, upgraded, or promoted automatically. It needs the system packages
from step 2 of [DEMO_ACCOUNT.md](DEMO_ACCOUNT.md), but no sudo membership and no
video/dialout groups.

The supplied timer runs at **03:00 Asia/Shanghai**, with up to 15 minutes of
jitter. Missed runs while PC2 is off are skipped, rather than starting a large
build as soon as the robot boots. Change the timer before installation if this
time is unsuitable.

## What runs daily

1. Clone a fresh launcher repository from `main` and check shell syntax.
2. Clone the XR fork and initialize its exact submodule pins. Authentication,
   missing commits, and missing Python project files fail the build. The runner
   does not substitute upstream or silently repair deleted source files.
3. Install a fresh Miniforge into that run's directory, using conda-forge only.
   Create a new Python environment; no interactive Anaconda ToS acceptance.
4. Build a separate ROS/DDS workspace, local SDK, and BrainCo service. Native
   build parallelism is limited to two workers.
5. Install Python dependencies with the repository's `python-constraints.txt`.
   Run `pip check`, imports of the SDK, XR libraries, NumPy, OpenCV and Pinocchio,
   an in-memory image encode/decode check, synthetic forward kinematics, editable
   source-path checks, and BrainCo shared-library linkage checks.
6. Generate configuration/certificates in the isolated workspace and check the
   supervisor's help path. Record logs, Git/submodule revisions, and package versions.

The test installer uses `--user-only --software-only --workspace-root DIR`.
Those last two options must be used together; `DIR` must not already exist.
Its DDS configuration uses loopback, camera discovery/configuration is skipped,
and no camera, hand, XR server, or DDS topic-list process is launched. Generated
configuration is a build artifact, not a replacement for demo's live configuration.

This catches installation, dependency, import, and native-build regressions.
It does **not** certify camera streaming, serial permissions, finger movement,
Quest connectivity/buttons, arm control, or real-time performance. Those still
need a separate supervised hardware test. `--no-motion` is not such a test boundary.

## 1. Account dwei — directory /home/dwei/unitree_g1_dev/pc2/vr_teleops

First commit/publish these pipeline changes and update this checkout: the daily
job clones GitHub, not the local working tree. An unpublished `--software-only`
implementation will make a daily run fail with an unknown-option error.

Preview without downloading, creating accounts, or running a build:

```bash
cd /home/dwei/unitree_g1_dev/pc2/vr_teleops
python3 daily_demo_build.py --dry-run
python3 -B -m unittest discover -s tests -v
```

## 2. Account dwei — same directory — one-time administrator provisioning

Install/verify the system packages described in [DEMO_ACCOUNT.md](DEMO_ACCOUNT.md)
step 2 first. Then create a dedicated account (omit useradd if it already exists):

```bash
sudo useradd --system --user-group --create-home \
  --home-dir /var/lib/teleop-ci --shell /usr/sbin/nologin teleop-ci
sudo install -d -o root -g root -m 0755 /opt/teleop-ci
sudo install -o root -g root -m 0644 daily_demo_build.py /opt/teleop-ci/
sudo install -o root -g root -m 0644 \
  ci/teleop-daily.service ci/teleop-daily.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

The service runs as `teleop-ci` with private devices, no privilege escalation,
read-only system files, hidden login home directories, and only its state
directory writable (plus private temporary storage). It limits CPU to 150% and
memory to 6 GiB. Review those limits for your Jetson before enabling the timer.

The service also requests IP filtering for the usual robot subnet
`192.168.123.0/24` and IPv4/IPv6 multicast. Adjust the subnet for different robot
wiring. systemd IP filtering requires host support; inspect service warnings.
Do not treat a manual invocation outside this service as equivalent isolation.
Downloads still require Internet access via the normal uplink.

## 3. Account dwei — same directory — manual first run

Start a build asynchronously under the service's unprivileged account:

```bash
sudo systemctl start --no-block teleop-daily.service
sudo journalctl -u teleop-daily.service -f
```

Ctrl+C exits the log viewer, not the build. To stop the build explicitly:

```bash
sudo systemctl stop teleop-daily.service
```

The Python runner has a four-hour timeout and kills the build process group on
timeout/interruption. systemd also stops the entire service control group. A
lock prevents overlapping runs that share the results directory.

## 4. Account dwei — any directory — inspect the result

```bash
sudo cat /var/lib/teleop-ci/results/latest.json
sudo systemctl status teleop-daily.service --no-pager
```

Each run is under `/var/lib/teleop-ci/results/runs/<UTC timestamp>-<id>/`:

| File | Purpose |
| --- | --- |
| `summary.json` | Running/passed/failed, failure stage, timing and platform |
| `build.log` | Full command output and installer stage markers |
| `revisions.json` | Exact launcher, dependency and XR submodule commits |
| `conda-packages.json` | Resolved Conda versions, when installation reached that stage |
| `pip-freeze.txt` | Resolved Python packages, when the environment exists |

`latest.json` is updated when a run starts and when it finishes. A forcibly killed
runner or power loss can leave `running`; check the service state in that case.
An unavailable GitHub/PyPI/Conda service is reported as a failed build too; use the
stage and log to distinguish external outages from a code regression.

The runner retains **two build workspaces** by default, deleting only `work/`
and `checkout/` payloads in its own marked older run directories. All summaries,
logs and package inventories are retained. Reserve space for two full builds
and monitor disk usage. Private certificates remain inside those workspaces;
do not upload whole run directories as public artifacts.

The installed runner is administrator-owned and does not auto-update itself.
The launcher/XR sources are freshly cloned every day. Reinstall
`daily_demo_build.py` and service/timer files when their orchestration changes.
Override `--ref`, `--repo`, `--xr-url`, `--timeout`, or `--keep-workspaces` in the
service ExecStart if needed. Only public repositories are used; personal Git
credentials and inherited Python/Conda configuration are not reused.

## 5. Account dwei — any directory — enable the schedule after the first run

```bash
sudo systemctl enable --now teleop-daily.timer
systemctl list-timers teleop-daily.timer --all
```

To disable future runs:

```bash
sudo systemctl disable --now teleop-daily.timer
```

This does not stop an already-running build; use the service stop command for
that. The pipeline writes local results and a failing service exit code; it
does not send email/Slack notifications or change the operational demo account.

## Known source issue

The XR fork has referenced a non-public `MoissanClub/teleimager` URL. If that
remains in the published `.gitmodules`, a fresh daily build should fail at
`prepare_xr_sources`, exposing the same issue a new demo user would encounter.
Publish the verified upstream URL correction in the XR fork to resolve it.
Keep the required `MoissanClub/televuer` fork and its pinned controller fixes.
