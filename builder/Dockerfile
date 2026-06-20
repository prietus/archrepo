# OPTIONAL — not used by the default fully-in-cluster deploy.
#
# The default setup runs stock `archlinux:base-devel` and injects the build logic via
# ConfigMaps (see Makefile `sync` + k8s/30-cronjob.yaml), so nothing here needs building.
#
# Keep/use this Dockerfile only if you later prefer a pre-baked image (e.g. built
# in-cluster with Kaniko and pushed to an in-cluster registry) to skip the per-run
# `pacman -Sy` of the build tooling.
FROM archlinux:base-devel

# pacman-contrib -> updpkgsums ; nvchecker -> nvchecker/nvcmp/nvtake ; jq used by scripts
RUN pacman -Syu --noconfirm --needed \
        git \
        nvchecker \
        pacman-contrib \
        jq \
        sudo \
        ca-certificates && \
    paccache -r -k0 2>/dev/null || true && \
    rm -rf /var/cache/pacman/pkg/*

# Unprivileged build user (uid 1000). makepkg refuses to run as root.
RUN useradd -m -u 1000 -U -G wheel builder && \
    printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder

# Repo content + tooling
COPY --chown=builder:builder pkgbuilds /home/builder/pkgbuilds
COPY --chown=builder:builder nvchecker /home/builder/nvchecker
COPY builder/scripts/build-repo.sh /usr/local/bin/build-repo.sh
RUN chmod +x /usr/local/bin/build-repo.sh

USER builder
WORKDIR /home/builder
ENV REPO_NAME=myrepo \
    REPO_ROOT=/srv/repo \
    ARCH=x86_64 \
    PKGBUILD_DIR=/home/builder/pkgbuilds \
    NVCHECKER_TOML=/home/builder/nvchecker/nvchecker.toml

ENTRYPOINT ["/usr/local/bin/build-repo.sh"]
