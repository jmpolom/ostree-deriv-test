ARG tag=latest

FROM ghcr.io/jmpolom/fedora-ostree-base:$tag

RUN useradd -U -c 'delete me' \
            -G wheel \
            -p '$y$j9T$kq/3XQD3zBDpUAOaxEZMj0$dbUPks0Mk8u0vh/XnAoFgPkffy7kx.Fb9ETyRJo6FP2' \
            default && \
    dnf5 install -y \
    container-selinux \
    containernetworking-plugins \
    crun \
    git \
    knot-resolver \
    knot-utils \
    passt \
    podman \
    podman-plugins \
    skopeo \
    slirp4netns && \
    ostree container commit

COPY etc/resolv.conf /etc/resolv.conf
COPY etc/systemd/network/all.network /etc/systemd/network/all.network
COPY etc/systemd/system-preset/10-dns.preset /etc/systemd/system-preset/10-dns.preset
