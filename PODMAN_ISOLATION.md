# Secure Podman Integration for Sandboxed Claude Code

This document outlines the architecture and implementation for securely integrating container runtimes (Podman / Docker) into the Bubblewrap sandbox.

---

## 1. The Problem: The Container Socket Escape Vector

In a default Bubblewrap setup, binding the host's Podman or Docker socket directly into the sandbox:

```bash
# INSECURE: Allows trivial sandbox escape
--bind "$XDG_RUNTIME/podman" "$XDG_RUNTIME/podman"
```

creates a **complete bypass of Bubblewrap's filesystem isolation**:

1. **Host Namespace Resolution**: The host Podman daemon runs *outside* the Bubblewrap sandbox in the host's mount namespace.
2. **Arbitrary Mounts**: Any process or agent inside the sandbox can send an API call to launch a container mounting sensitive host directories:
   ```bash
   podman run --rm -v /home/alex/.pi:/target:ro alpine ls -la /target
   ```
3. **Sensitive Data Exposure**: Even if Bubblewrap hides `~/.pi`, `~/.ssh`, or `~/.gnupg`, the container engine mounts the real files directly from the host.

To allow tools like **Testcontainers**, **Docker CLI**, and language SDKs to run inside the sandbox without compromising the host filesystem, the container execution environment must be strictly decoupled from the host's root namespace.

---

## 2. Architecture Overview

The solution consists of three complementary layers:

```
┌────────────────────────────────────────────────────────────────────────┐
│                              HOST MACHINE                              │
│                                                                        │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │ 1. Local Pull-Through Registry Mirror (localhost:5000)         │   │
│   │    - Caches Docker Hub image blobs in ~/.cache/docker-registry │   │
│   │    - Completely lock-free, zero-risk of image tampering       │   │
│   └────────────────────────────────────────────────────────────────┘   │
│                                   │                                    │
│                   ┌───────────────┴───────────────┐                    │
│                   ▼                               ▼                    │
│   ┌───────────────────────────────┐ ┌──────────────────────────────┐   │
│   │ OPTION A: Centralized Daemon  │ │ OPTION B: Per-Session Daemon │   │
│   │ - One shared PinP container   │ │ - Ephemeral PinP container   │   │
│   │ - Scoped to ~/Code            │ │ - Scoped strictly to $PWD    │   │
│   │ - Instant session startup     │ │ - Total session isolation    │   │
│   └───────────────────────────────┘ └──────────────────────────────┘   │
│                   │                               │                    │
│                   └───────────────┬───────────────┘                    │
│                                   │ (Exposes isolated socket)          │
│                                   ▼                                    │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │ 2. Preconfigured Bubblewrap Sandbox                            │   │
│   │    - Direct network loopback (--share-net -> localhost:5000)   │   │
│   │    - Standard /var/run/docker.sock compatibility               │   │
│   │    - Auto-configured DOCKER_HOST and Testcontainers env vars   │   │
│   │    - Transparent to Maven, Gradle, Node, Python, and CLI       │   │
│   └────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Shared Registry Cache (`localhost:5000`)

### Why Not Share Host Image Storage Directly (RW)?

Sharing the host's on-disk image storage (`~/.local/share/containers`) with RW permissions leads to:
* **Database lock contention**: `containers/storage` uses local file locks (`storage.db`, `db.lock`) not designed for concurrent multi-daemon access.
* **Corrupted image downloads**: Simultaneous pulls of identical layers corrupt tarball extractions.
* **Kernel OverlayFS violations**: Modifying underlying lower directories while mounted causes `ESTALE` errors.
* **Image poisoning**: Compromised code in one sandbox could overwrite shared binaries in cached layers (e.g., modifying `node:20` or `alpine`).

### The Pull-Through Mirror Solution

Running an official OCI pull-through mirror on `localhost:5000`:
* Handles concurrent downloads and caching automatically over HTTP.
* Keeps host storage completely isolated from the sandbox.
* Serves cached layers to all sandboxes at loopback speeds.

### Host Setup

Start the caching registry on your host (run once or enable as a systemd user service):

```bash
mkdir -p "$HOME/.cache/docker-registry"

podman run -d \
  --name claude-registry-cache \
  --restart=always \
  -p 5000:5000 \
  -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
  -v "$HOME/.cache/docker-registry":/var/lib/registry \
  registry:2
```

### Registry Configuration (`registries.conf`)

Save this file as `$HOME/.config/containers/registries.conf`:

```toml
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "localhost:5000"
insecure = true
```

---

## 4. Preconfigured Sandbox: 100% Transparent Tooling

In projects using containerized testing (e.g. `feature-flags-management` with Java Testcontainers), developers are often required to remember manual boilerplate:

```bash
# Manual boilerplate previously required in documentation:
DOCKER_HOST="unix:///run/user/1000/podman/podman.sock" \
TESTCONTAINERS_RYUK_DISABLED=true \
./mvnw test -pl application
```

The sandbox configuration automates this so that **any tool works out of the box** without extra flags.

### Sandbox Environment & Path Injection

Add these bindings to `bubblewrap_claude.sh`:

```bash
# 1. Provide standard Docker socket paths for tools that check /var/run/docker.sock
CONTAINER_SYMLINKS="--dir /var/run --symlink $XDG_RUNTIME/podman/podman.sock /var/run/docker.sock"

# 2. Configure environment variables globally for the sandbox session
CONTAINER_ENV="--setenv DOCKER_HOST unix://$XDG_RUNTIME/podman/podman.sock"
CONTAINER_ENV="$CONTAINER_ENV --setenv TESTCONTAINERS_RYUK_DISABLED true"
CONTAINER_ENV="$CONTAINER_ENV --setenv TESTCONTAINERS_CHECKS_DISABLE true"

# 3. Bind the mirror configuration
CONTAINER_CONF="--ro-bind $HOME/.config/containers/registries.conf /etc/containers/registries.conf"
```

With these settings:
* Java Testcontainers, Python Docker SDK, and Node libraries automatically find the daemon.
* Ryuk's unsupported privileged operations under rootless containers are suppressed.
* `./mvnw test`, `docker ps`, or `podman run` run transparently without environment prefixes.

---

## 5. Daemon Isolation: Choose Your Strategy

Choose between **Option A (Centralized)** or **Option B (Per-Sandbox)** based on your workflow requirements.

| Feature | Option A: Centralized Daemon | Option B: Per-Sandbox Daemon |
| :--- | :--- | :--- |
| **Startup Overhead** | **0ms** (instant) | **~1–2 seconds** per session |
| **Mount Boundary** | Broad (e.g. `$HOME/Code`) | Strict (only current `$PWD`) |
| **Parallel Sessions** | Shared container namespace | Fully isolated container namespace |
| **Container Collisions** | Possible (`--name my-db` collision) | Impossible (isolated environments) |
| **Maintenance** | Single background service | Fully automated cleanup on exit |

---

### Option A: Centralized Isolated Podman Daemon

A single persistent Podman-in-Podman (PinP) container runs on the host and serves all Claude Code sessions.

#### How It Works:
* Confined strictly to your development root (e.g. `$HOME/Code`).
* Has no visibility into `~/.pi`, `~/.ssh`, or host system files.
* All parallel Claude sessions connect to the same background daemon socket.

#### 1. Setup the Host Service

Create a systemd user unit at `~/.config/systemd/user/claude-podman.service`:

```ini
[Unit]
Description=Isolated Podman Daemon for Claude Sandboxes
After=network.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f claude-podman-shared
ExecStartPre=/usr/bin/mkdir -p %t/claude-podman
ExecStart=/usr/bin/podman run --rm --name claude-podman-shared \
  --privileged \
  --net=host \
  -v %t/claude-podman:/run/podman \
  -v %h/Code:%h/Code \
  -v %h/.config/containers/registries.conf:/etc/containers/registries.conf:ro \
  quay.io/podman/stable \
  podman system service --time=0 unix:///run/podman/podman.sock
ExecStop=/usr/bin/podman stop -t 2 claude-podman-shared
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
```

Enable and start it:
```bash
systemctl --user daemon-reload
systemctl --user enable --now claude-podman.service
```

#### 2. Update `bubblewrap_claude.sh`

```bash
SHARED_PODMAN_SOCK="$XDG_RUNTIME/claude-podman/podman.sock"

if [ -S "$SHARED_PODMAN_SOCK" ]; then
  PODMAN_BINDS="--bind $SHARED_PODMAN_SOCK $XDG_RUNTIME/podman/podman.sock"
fi
```

#### 3. Volume Storage and Lifecycle in Option A

Where volumes physically live and how long they persist depends on the volume type:

| Volume Type | Physical Storage Location | Survives Claude Exit? | Survives Host Reboot / Service Restart? |
| :--- | :--- | :--- | :--- |
| **Host Bind Mount** (`-v $PWD:...` or `-v ~/Code/...`) | `$HOME/Code/...` (Host filesystem) | **Yes** (Real project files) | **Yes** |
| **Named Volume** (`-v my_vol:...`) | Inside `claude-podman-shared` container storage (`/var/lib/containers/storage/volumes/`) | **Yes** (Shared across concurrent sessions) | **No** (Wiped when service restarts) |
| **Anonymous / Tmpfs Volume** (`-v /data`) | Ephemeral copy-on-write layer | **No** (Deleted with container) | **No** |

* **Default Behavior (Ephemeral Named Volumes)**:
  Because `claude-podman-shared` runs with `--rm`, named volumes and container state are automatically wiped whenever the background service restarts or the host reboots. This is generally preferred for development and test frameworks (such as Testcontainers) because it prevents orphaned database volumes from accumulating on the host.

* **Optional: Persisting Named Volumes Across Reboots**:
  If you need named volumes (e.g., persistent local development databases) to survive system reboots and daemon restarts, add a dedicated storage mount to `ExecStart` in `claude-podman.service`:
  ```ini
  -v %h/.local/share/claude-podman-volumes:/var/lib/containers/storage/volumes \
  ```

---

### Option B: Per-Sandbox Ephemeral Podman Daemon

Each time `bubblewrap_claude.sh` is executed, it spins up an independent, throwaway Podman daemon container strictly mapped to the current working directory (`$PWD`).

#### How It Works:
* Maximum isolation: Session A cannot see Session B's containers, networks, or volumes.
* Path containment: Only the repository Claude was launched in (`$PWD`) is mounted.
* Lifecycle bound: The daemon terminates and removes itself as soon as Claude Code exits.

#### Implementation in `bubblewrap_claude.sh`:

```bash
# 1. Generate unique session ID and temporary runtime directory
SESSION_ID="claude-pinp-$$"
PINP_DIR=$(mktemp -d "/tmp/${SESSION_ID}.XXXXXX")

# 2. Launch ephemeral PinP container on host before entering bwrap
echo "Initializing isolated container environment..."
podman run -d --rm \
  --name "$SESSION_ID" \
  --privileged \
  --net=host \
  -v "$PINP_DIR":/run/podman \
  -v "$PWD":"$PWD" \
  -v "$HOME/.config/containers/registries.conf":/etc/containers/registries.conf:ro \
  quay.io/podman/stable \
  podman system service --time=0 unix:///run/podman/podman.sock >/dev/null

# 3. Clean up container and temporary socket directory on exit
cleanup_pinp() {
  podman stop -t 1 "$SESSION_ID" >/dev/null 2>&1
  rm -rf "$PINP_DIR"
}
trap cleanup_pinp EXIT INT TERM

# 4. Wait for daemon socket to become ready
while [ ! -S "$PINP_DIR/podman.sock" ]; do
  sleep 0.05
done

# 5. Bind ephemeral socket into Bubblewrap
PODMAN_BINDS="--bind $PINP_DIR/podman.sock $XDG_RUNTIME/podman/podman.sock"
```

#### Volume Storage and Lifecycle in Option B:
* **Host Bind Mounts (`-v $PWD:...`)**: Mapped directly to your current project directory on the host; changes made by containers persist in your working copy.
* **Named & Anonymous Volumes**: Stored inside the ephemeral PinP container and are **100% destroyed on session exit** when the trap triggers `podman stop`. No residual test databases or anonymous volumes remain on the host.

---

## 6. Verification and Security Validation

After applying either Option A or Option B, verify that both the security boundary and the test environment function correctly.

### Security Test: Attempt Host Breakout
From inside the sandboxed Claude Code terminal:

```bash
# Attempt to mount ~/.pi via the container runtime
podman run --rm -v /home/alex/.pi:/target:ro alpine ls /target
```
* **Expected Result**: `Error: statfs /home/alex/.pi: no such file or directory`. The daemon cannot see or resolve the path.

### Functionality Test: Run Testcontainers
From inside `~/Code/PRO/feature-flags-management`:

```bash
# No flags or environment variables required
./mvnw test -pl application
```
* **Expected Result**: 
  1. Testcontainers connects via `/var/run/docker.sock` or `$DOCKER_HOST`.
  2. Images are pulled via `localhost:5000` from the local cache.
  3. Tests execute and containers terminate cleanly.
