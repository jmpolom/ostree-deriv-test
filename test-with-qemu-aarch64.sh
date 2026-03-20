#!/usr/bin/bash

set -Eeuo pipefail

DERIVATIVE_IMAGE="${DERIVATIVE_IMAGE:-ghcr.io/jmpolom/fedora-ostree-base:latest}"
INSTALL_TARGET_DISK="${INSTALL_TARGET_DISK:-/dev/nvme0n1}"

ISO_PATH="${ISO_PATH:-./output/bootiso/install.iso}"
VARS_FILE="${VARS_FILE:-./vars.fd}"
EDK2_CODE="${EDK2_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

NVME_INSTALL_IMAGE="${NVME_INSTALL_IMAGE:-./disk-install.qcow2}"
NVME_EXTRA_IMAGE="${NVME_EXTRA_IMAGE:-./disk-extra.qcow2}"
NVME_SIZE="${NVME_SIZE:-40G}"

TMP_DIR="${TMP_DIR:-./tmp/qemu-aarch64-install}"
LIVE_IGNITION_PATH="${LIVE_IGNITION_PATH:-${TMP_DIR}/live.ign}"
SERIAL_LOG="${SERIAL_LOG:-${TMP_DIR}/serial.log}"
QMP_SOCK="${QMP_SOCK:-${TMP_DIR}/qmp.sock}"
TPM_DIR="${TPM_DIR:-${TMP_DIR}/tpm}"
TPM_SOCK="${TPM_SOCK:-${TPM_DIR}/swtpm.sock}"

BOOT_MENU_DELAY_SECS="${BOOT_MENU_DELAY_SECS:-8}"
GRUB_KERNEL_LINE_DOWNS="${GRUB_KERNEL_LINE_DOWNS:-2}"
LIVE_KARGS="${LIVE_KARGS:-ignition.firstboot ignition.platform.id=qemu}"

QEMU_ACCEL="${QEMU_ACCEL:-hvf}"
QEMU_CPU="${QEMU_CPU:-host}"
QEMU_DISPLAY="${QEMU_DISPLAY:-cocoa,show-cursor=on}"
QEMU_MEMORY="${QEMU_MEMORY:-4G}"
QEMU_SMP="${QEMU_SMP:-4}"

readonly DERIVATIVE_IMAGE
readonly INSTALL_TARGET_DISK
readonly ISO_PATH
readonly VARS_FILE
readonly EDK2_CODE
readonly NVME_INSTALL_IMAGE
readonly NVME_EXTRA_IMAGE
readonly NVME_SIZE
readonly TMP_DIR
readonly LIVE_IGNITION_PATH
readonly SERIAL_LOG
readonly QMP_SOCK
readonly TPM_DIR
readonly TPM_SOCK
readonly BOOT_MENU_DELAY_SECS
readonly GRUB_KERNEL_LINE_DOWNS
readonly LIVE_KARGS
readonly QEMU_ACCEL
readonly QEMU_CPU
readonly QEMU_DISPLAY
readonly QEMU_MEMORY
readonly QEMU_SMP

SWTPM_PID=""
QEMU_PID=""

require_commands() {
    local missing=()
    local cmd

    for cmd in \
        base64 \
        qemu-img \
        qemu-system-aarch64 \
        socat \
        swtpm
    do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    if ((${#missing[@]} > 0)); then
        printf 'Missing required commands: %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

require_files() {
    local path

    for path in "${ISO_PATH}" "${VARS_FILE}" "${EDK2_CODE}"; do
        if [[ ! -f "${path}" ]]; then
            printf 'Required file not found: %s\n' "${path}" >&2
            exit 1
        fi
    done
}

cleanup() {
    set +e

    if [[ -n "${QEMU_PID}" ]]; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
    fi

    if [[ -n "${SWTPM_PID}" ]]; then
        kill "${SWTPM_PID}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

mkdir -p "${TMP_DIR}" "${TPM_DIR}"

data_url_from_string() {
    printf 'data:text/plain;charset=utf-8;base64,%s' \
        "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

create_live_ignition() {
    local wrapper unit
    local wrapper_source unit_source

    wrapper=$(cat <<EOF
#!/usr/bin/bash
set -Eeuo pipefail

image_ref="${DERIVATIVE_IMAGE}"
target_disk="${INSTALL_TARGET_DISK}"
embedded_install_path="/usr/lib/bootc/install-scripts/install"
extracted_install_path="/usr/local/sbin/bootc-test-install"
container_id=""

cleanup() {
    set +e

    if [[ -n "\${container_id}" ]]; then
        podman rm -f "\${container_id}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

echo "Pulling \${image_ref}"
podman pull "\${image_ref}"

container_id="$(podman create "\${image_ref}")"
podman cp "\${container_id}:\${embedded_install_path}" "\${extracted_install_path}"
chmod 0755 "\${extracted_install_path}"

echo "Running extracted installer against \${target_disk}"
CONTAINER_IMAGE="\${image_ref}" TARGET_DISK="\${target_disk}" "\${extracted_install_path}"
touch /var/lib/bootc-qemu-install.completed
EOF
)

    unit=$(cat <<'EOF'
[Unit]
Description=Run bootc install test from embedded image script
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/bootc-qemu-install.completed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/run-bootc-install-from-image
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
)

    wrapper_source="$(data_url_from_string "${wrapper}")"
    unit_source="$(data_url_from_string "${unit}")"

    cat >"${LIVE_IGNITION_PATH}" <<EOF
{
  "ignition": {
    "version": "3.4.0"
  },
  "storage": {
    "files": [
      {
        "path": "/usr/local/sbin/run-bootc-install-from-image",
        "mode": 493,
        "overwrite": true,
        "contents": {
          "source": "${wrapper_source}"
        }
      },
      {
        "path": "/etc/systemd/system/bootc-qemu-install.service",
        "mode": 420,
        "overwrite": true,
        "contents": {
          "source": "${unit_source}"
        }
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "bootc-qemu-install.service",
        "enabled": true
      }
    ]
  }
}
EOF
}

create_disks() {
    if [[ ! -f "${NVME_INSTALL_IMAGE}" ]]; then
        qemu-img create -f qcow2 "${NVME_INSTALL_IMAGE}" "${NVME_SIZE}" >/dev/null
    fi

    if [[ ! -f "${NVME_EXTRA_IMAGE}" ]]; then
        qemu-img create -f qcow2 "${NVME_EXTRA_IMAGE}" "${NVME_SIZE}" >/dev/null
    fi
}

start_swtpm() {
    rm -f "${TPM_SOCK}"

    swtpm socket \
        --tpmstate "dir=${TPM_DIR}" \
        --ctrl "type=unixio,path=${TPM_SOCK}" \
        --tpm2 \
        --log level=20 &
    SWTPM_PID="$!"
}

wait_for_socket() {
    local socket_path="$1"
    local timeout="${2:-30}"
    local waited=0

    while [[ ! -S "${socket_path}" ]]; do
        sleep 1
        waited=$((waited + 1))
        if ((waited >= timeout)); then
            printf 'Timed out waiting for socket: %s\n' "${socket_path}" >&2
            exit 1
        fi
    done
}

qmp_cmd() {
    local command="$1"

    {
        printf '{ "execute": "qmp_capabilities" }\n'
        printf '%s\n' "${command}"
    } | socat - UNIX-CONNECT:"${QMP_SOCK}" >/dev/null
}

qmp_sendkey() {
    local key="$1"

    qmp_cmd "{ \"execute\": \"human-monitor-command\", \"arguments\": { \"command-line\": \"sendkey ${key}\" } }"
    sleep 0.1
}

qmp_send_text() {
    local text="$1"
    local idx
    local char

    for ((idx = 0; idx < ${#text}; idx++)); do
        char="${text:idx:1}"

        case "${char}" in
            ' ') qmp_sendkey spc ;;
            '.') qmp_sendkey dot ;;
            '=') qmp_sendkey equal ;;
            '-') qmp_sendkey minus ;;
            [a-z0-9]) qmp_sendkey "${char}" ;;
            *)
                printf 'Unsupported key for QMP text injection: %s\n' "${char}" >&2
                exit 1
                ;;
        esac
    done
}

append_live_kernel_args() {
    local count

    sleep "${BOOT_MENU_DELAY_SECS}"

    qmp_sendkey e
    sleep 1

    for ((count = 0; count < GRUB_KERNEL_LINE_DOWNS; count++)); do
        qmp_sendkey down
    done

    qmp_sendkey end
    qmp_sendkey spc
    qmp_send_text "${LIVE_KARGS}"
    qmp_sendkey ctrl-x
}

start_qemu() {
    rm -f "${QMP_SOCK}" "${SERIAL_LOG}"

    qemu-system-aarch64 \
        -M virt,highmem=on \
        -accel "${QEMU_ACCEL}" \
        -cpu "${QEMU_CPU}" \
        -smp "${QEMU_SMP}" \
        -m "${QEMU_MEMORY}" \
        -device virtio-gpu-pci \
        -display "${QEMU_DISPLAY}" \
        -device qemu-xhci \
        -device usb-kbd \
        -device usb-tablet \
        -drive if=pflash,format=raw,readonly=on,file="${EDK2_CODE}" \
        -drive if=pflash,format=raw,file="${VARS_FILE}" \
        -drive file="${NVME_INSTALL_IMAGE}",if=none,id=nvm1 \
        -device nvme,serial=nvme-install,drive=nvm1 \
        -drive file="${NVME_EXTRA_IMAGE}",if=none,id=nvm2 \
        -device nvme,serial=nvme-extra,drive=nvm2 \
        -drive file="${ISO_PATH}",media=cdrom,if=none,id=install_cd \
        -device virtio-scsi-pci \
        -device scsi-cd,drive=install_cd \
        -fw_cfg "name=opt/com.coreos/config,file=${LIVE_IGNITION_PATH}" \
        -chardev "socket,id=chrtpm,path=${TPM_SOCK}" \
        -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
        -device "tpm-tis-device,tpmdev=tpm0" \
        -qmp "unix:${QMP_SOCK},server=on,wait=off" \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -serial "file:${SERIAL_LOG}" &

    QEMU_PID="$!"
}

main() {
    require_commands
    require_files
    create_live_ignition
    create_disks
    start_swtpm
    wait_for_socket "${TPM_SOCK}" 30
    start_qemu
    wait_for_socket "${QMP_SOCK}" 30
    append_live_kernel_args
    wait "${QEMU_PID}"
}

main "$@"
