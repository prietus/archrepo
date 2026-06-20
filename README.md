# archrepo — custom Arch Linux package repository on Kubernetes

A self-hosted pacman repository that **watches upstream versions** and automatically
rebuilds packages when a new release appears. Packages are **GPG-signed**, stored on a
**PVC**, and served by **nginx** behind an Ingress.

**Fully in-cluster: no custom image, no registry, no external CI.** The builder runs the
stock official `archlinux:base-devel` image; the build logic and your PKGBUILDs are
shipped into the cluster as ConfigMaps. Everything is `kubectl apply`. The only things
pulled from outside are public base images (`archlinux`, `nginx`) — unavoidable for any
cluster.

## The live repo

This instance is running and serving packages right now:

| | |
|---|---|
| **Repo name** | `myrepo` |
| **URL** | <https://archrepo.priet.us/$arch> (i.e. `…/x86_64`) |
| **Arch** | `x86_64` |
| **Signing key** | `A55728913D61E6A349664C9F6BAB541F79DF2E87` — *Carlos Arch Repo \<cprieto.ortiz@gmail.com\>* |
| **Public key** | <https://archrepo.priet.us/archrepo-signing-key.pub> |

The packages it builds and signs are exactly the directories under `pkgbuilds/`
(murmur-bin, the caelestia stack, quickshell-git, syshud, the plymouth theme, etc.).

### Enable it on an Arch client

```bash
# 1. Trust the repo's signing key (one-time)
curl -fsSL -o /tmp/archrepo.pub https://archrepo.priet.us/archrepo-signing-key.pub
sudo pacman-key --add /tmp/archrepo.pub
sudo pacman-key --lsign-key A55728913D61E6A349664C9F6BAB541F79DF2E87
```
> Use the **full fingerprint** above for `--lsign-key`; a truncated key ID fails with
> *"No se ha podido firmar … localmente"*.

```ini
# 2. Append to /etc/pacman.conf  (put it below the official repos)
[myrepo]
SigLevel = Required
Server = https://archrepo.priet.us/$arch
```

```bash
# 3. Refresh all DBs + full upgrade, then install
sudo pacman -Syu
sudo pacman -S caelestia-meta        # or any package listed under pkgbuilds/
```
> Use `-Syu`, **not** `-Sy`. A bare `pacman -Sy pkg` refreshes the DBs without upgrading the
> system — a *partial upgrade*, which Arch explicitly discourages (a package may be linked
> against newer libs than the ones you have installed). Always sync and upgrade together.

Updates are automatic: the in-cluster CronJob re-checks upstream versions hourly, so a new
release lands in `myrepo` within ~1 h and reaches you on the next `pacman -Syu`.

## How it works

```
            ┌──────────────────── CronJob (hourly, archlinux:base-devel) ───────────────┐
            │  [root]  pacman -Sy nvchecker/makepkg tooling → unpack ConfigMaps          │
            │            ↓ drop to unprivileged `builder` user                           │
            │  nvchecker → detect new upstream version                                   │
            │            ↓                                                               │
            │  bump pkgver + pkgrel=1 → updpkgsums → makepkg --sign                       │
            │            ↓                                                               │
            │  copy .pkg.tar.zst(.sig) to PVC → repo-add --sign → myrepo.db              │
            │            ↓                                                               │
            │  nvtake (record built version so it isn't rebuilt next run)                │
            └────────────────────────────────────────────────────────────────────────────┘
                                       │  shared PVC: /srv/repo
                                       ▼
                       nginx Deployment → Service → Ingress
                                       ▼
                     pacman clients (SigLevel = Required)
```

State that must survive a pod restart lives on the PVC under `/srv/repo`:
- `x86_64/*.pkg.tar.zst(.sig)` — the built, signed packages
- `x86_64/myrepo.db*` — the pacman database (signed)
- `state/old_ver.json`, `state/new_ver.json` — nvchecker version history
- `.cache/pacman-pkg/` — cached build tooling, so hourly runs don't re-download

## How the code gets into the cluster

There is no image to build. `make sync` packages two things and applies them as ConfigMaps:

| ConfigMap | Content | Mounted at |
|-----------|---------|-----------|
| `archrepo-build-script` | `builder/scripts/build-repo.sh` | `/scripts` |
| `archrepo-src` | tarball of `pkgbuilds/` + `nvchecker/` | `/src` (unpacked to `/home/builder`) |

The CronJob's entrypoint (`bash /scripts/build-repo.sh`) starts as root, installs the
build tooling, unpacks `/src`, then re-execs itself as the unprivileged `builder` user
(makepkg refuses to run as root).

## Layout

| Path | Purpose |
|------|---------|
| `pkgbuilds/<name>/PKGBUILD` | one directory per package |
| `nvchecker/nvchecker.toml`  | which upstream to watch (section name = dir name) |
| `builder/scripts/build-repo.sh` | check→build→sign→publish logic (runs in-cluster) |
| `k8s/*.yaml`                | namespace, PVC, GPG secret, CronJob, nginx, ingress |
| `scripts/create-gpg-secret.sh` | generate signing key + create Secret |
| `scripts/trigger-build.sh`  | run a build immediately |
| `builder/Dockerfile`        | OPTIONAL — only if you later want a pre-baked image |

## Setup

### 1. Signing key + Secret
```bash
NAME="Carlos Arch Repo" EMAIL="repo@carlos.dev" ./scripts/create-gpg-secret.sh
# writes archrepo-signing-key.pub and creates Secret archrepo-gpg in ns archrepo
```
> Uses a passphrase-less key (protected by Kubernetes RBAC). For a passphrase-protected
> key, add a `gpg-passphrase` entry to the Secret — the script reads it from
> `/secrets/gpg-passphrase` automatically.

### 2. Configure
- Edit `k8s/50-ingress.yaml` → set `host:` and `ingressClassName`.
- Check `k8s/10-pvc.yaml` → if your cluster is multi-node, use a **ReadWriteMany**
  StorageClass (the builder and nginx mount the same PVC concurrently).

### 3. Deploy
```bash
make deploy      # syncs ConfigMaps + applies all manifests
make trigger     # build now instead of waiting for the hourly tick
make logs        # watch it build the example `hello` package
```

> The CronJob runs on **amd64/Arch** — make sure the nodes that run it are amd64.

## Add a package

1. Create `pkgbuilds/<name>/PKGBUILD`.
2. Add a `[<name>]` section to `nvchecker/nvchecker.toml` pointing at its upstream
   ([source list](https://nvchecker.readthedocs.io/en/latest/usage.html)).
3. Push the change into the cluster and build:
   ```bash
   make sync && make trigger
   ```

The committed `pkgver`/checksums are only a baseline — the builder rewrites them from the
upstream version at build time.

> ConfigMaps have a ~1 MiB limit. Text PKGBUILDs are tiny, but if a package needs large
> binary patches, host those via `source=()` URLs rather than committing them.

## Use the repo from a client

For the **live instance**, see [The live repo](#the-live-repo) above. Generically: trust
the signing key (`pacman-key --add` + `--lsign-key <fingerprint>`), then add a `[myrepo]`
section to `/etc/pacman.conf` with `SigLevel = Required` and `Server = https://<host>/$arch`.

> `Server` ends in `$arch`, resolving to `/srv/repo/x86_64`. The database is `myrepo.db`,
> matching `REPO_NAME=myrepo`.

## Operations

| Task | Command |
|------|---------|
| Ship code + build now | `make sync && make trigger`, then `make logs` |
| See pods/jobs/ingress | `make status` |
| Change schedule | edit `schedule:` in `k8s/30-cronjob.yaml` |
| Rename the repo | set `REPO_NAME` in the cronjob env and the `[myrepo]` client section |

## Notes & limits

- **VCS / `pkgver()` packages** (`-git`): supported. The builder detects a `pkgver()`
  function and skips the `pkgver=` rewrite + `updpkgsums`, letting makepkg compute the
  version from the cloned source. Track these with a `git` source + `use_commit` in
  `nvchecker.toml` so a new upstream commit triggers a rebuild.
- **pkgrel-only rebuilds** (soname bumps from dependency updates) aren't auto-triggered —
  this reacts to *upstream version* changes only.
- **GitHub rate limits**: add a token via the optional `nvchecker-keyfile` Secret entry.
- **Concurrency**: `concurrencyPolicy: Forbid` + a single nginx replica keep PVC writers
  serialized. Don't scale nginx past 1 on a ReadWriteOnce PVC.
- **Want a pre-baked image instead?** Use `builder/Dockerfile` with an in-cluster registry
  (`registry:2`) + Kaniko build Job to avoid the per-run `pacman -Sy`. More moving parts;
  the ConfigMap approach above is the simpler default.
