FROM ghcr.io/jmpolom/fedora-ostree-base:latest

COPY dnf.conf /etc/dnf/dnf.conf
RUN useradd -U -c 'test creating user during deriv build' \
            -G wheel \
            -p '$y$j9T$kq/3XQD3zBDpUAOaxEZMj0$dbUPks0Mk8u0vh/XnAoFgPkffy7kx.Fb9ETyRJo6FP2' \
            default && \
    rpm-ostree install neovim && \
    ostree container commit
