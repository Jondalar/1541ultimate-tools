#!/usr/bin/env bash
# probe.sh — Docker image capability detection and --check-support
#
# Depends on: repo.sh (repo_has_all_files), docker.sh (capture_docker_script_output),
#             logging.sh, $SW_ONLY, $TARGETS[], $DOCKER_IMAGE, $BUILD_TOOLS_DIR

probe_image_capabilities() {
    IMAGE_HAS_RISCV=0  IMAGE_HAS_NIOS=0    IMAGE_HAS_QUARTUS=0
    IMAGE_HAS_XILINX=0 IMAGE_HAS_LATTICE=0 IMAGE_HAS_IDF=0
    IMAGE_HAS_ESP32=0  IMAGE_HAS_ESP32C3=0  IMAGE_HAS_ESP32S3=0

    local output
    output=$(capture_docker_script_output "
echo RISCV=\$(command -v riscv32-unknown-elf-gcc >/dev/null 2>&1 && echo yes || echo no)
echo NIOS=\$(command -v nios2-elf-gcc >/dev/null 2>&1 && echo yes || echo no)
echo QUARTUS=\$(command -v quartus_sh >/dev/null 2>&1 && echo yes || echo no)
if [ -n \"\${ISE_LOCATIONS_FILE_PATH:-}\" ] && [ -f \"\${ISE_LOCATIONS_FILE_PATH}\" ]; then
    echo XILINX=yes
else
    echo XILINX=\$(command -v xst >/dev/null 2>&1 && echo yes || echo no)
fi
echo LATTICE=\$(command -v diamondc >/dev/null 2>&1 && echo yes || echo no)
echo IDF=\$(command -v idf.py >/dev/null 2>&1 && echo yes || echo no)
if command -v idf.py >/dev/null 2>&1; then
    idf.py --list-targets 2>/dev/null | tr '\n' ' ' | sed 's/^/IDF_TARGETS=/'
fi
")

    case "$output" in *$'RISCV=yes'*)   IMAGE_HAS_RISCV=1 ;;   esac
    case "$output" in *$'NIOS=yes'*)    IMAGE_HAS_NIOS=1 ;;    esac
    case "$output" in *$'QUARTUS=yes'*) IMAGE_HAS_QUARTUS=1 ;;  esac
    case "$output" in *$'XILINX=yes'*)  IMAGE_HAS_XILINX=1 ;;  esac
    case "$output" in *$'LATTICE=yes'*) IMAGE_HAS_LATTICE=1 ;; esac
    case "$output" in *$'IDF=yes'*)     IMAGE_HAS_IDF=1 ;;     esac
    case "$output" in
        *'IDF_TARGETS='*' esp32 '*|*'IDF_TARGETS=esp32 '*|*'IDF_TARGETS='*' esp32')
            IMAGE_HAS_ESP32=1 ;;
    esac
    case "$output" in
        *'IDF_TARGETS='*' esp32c3 '*|*'IDF_TARGETS=esp32c3 '*|*'IDF_TARGETS='*' esp32c3')
            IMAGE_HAS_ESP32C3=1 ;;
    esac
    case "$output" in
        *'IDF_TARGETS='*' esp32s3 '*|*'IDF_TARGETS=esp32s3 '*|*'IDF_TARGETS='*' esp32s3')
            IMAGE_HAS_ESP32S3=1 ;;
    esac
}

# _probe_line TARGET STATUS REASON — internal pipe-delimited record
_probe_line() {
    printf '%s|%s|%s\n' "$1" "$2" "$3"
}

# probe_target_support TARGET — emit a _probe_line describing buildability
probe_target_support() {
    local target=$1
    local status=unsupported reason="unknown"

    case "$target" in
        u2)
            if [ "$SW_ONLY" -eq 1 ]; then
                if [ "$IMAGE_HAS_RISCV" -ne 1 ]; then
                    reason="missing RISC-V toolchain"
                elif repo_has_all_files \
                    target/u2/riscv/ultimate/result/ultimate.bin \
                    target/u2/riscv/boot2/result/boot2.bin \
                    target/fpga/rv700dd/rv700dd/rv700dd.bin \
                    target/fpga/rv700au/work/rv700au.bin; then
                    status=supported
                    reason="repo has cached FPGA/boot artifacts needed by u2_rv_swonly"
                else
                    reason="u2_rv_swonly still needs cached rv700dd/rv700au and boot2 artifacts in the repo"
                fi
            else
                if [ "$IMAGE_HAS_RISCV" -eq 1 ] && [ "$IMAGE_HAS_XILINX" -eq 1 ]; then
                    status=supported
                    reason="RISC-V and Xilinx ISE toolchains are available"
                elif [ "$IMAGE_HAS_XILINX" -ne 1 ]; then
                    reason="missing Xilinx ISE toolchain"
                else
                    reason="missing RISC-V toolchain"
                fi
            fi
            ;;
        u2plus)
            if [ "$IMAGE_HAS_NIOS" -eq 1 ] && [ "$IMAGE_HAS_QUARTUS" -eq 1 ]; then
                if [ "$SW_ONLY" -eq 1 ]; then
                    if repo_has_all_files \
                        target/fpga/u2plus_recovery/output_files/ultimate_recovery.rbf \
                        target/fpga/u2plus_run/output_files/ultimate_run.rbf; then
                        status=supported
                        reason="Quartus/Nios are available and cached U2+ FPGA outputs exist"
                    else
                        reason="u2plus_swonly needs cached ultimate_recovery.rbf and ultimate_run.rbf"
                    fi
                else
                    status=supported
                    reason="Quartus and Nios toolchains are available"
                fi
            else
                reason="missing Quartus/Nios toolchain"
            fi
            ;;
        u2pl)
            if [ "$SW_ONLY" -eq 1 ]; then
                if [ "$IMAGE_HAS_RISCV" -ne 1 ]; then
                    reason="missing RISC-V toolchain"
                elif [ "$IMAGE_HAS_ESP32C3" -ne 1 ]; then
                    reason="missing ESP32-C3 target support in ESP-IDF"
                elif repo_has_all_files \
                    target/fpga/u2plus_ecp5/impl1/u2p_ecp5_impl1.bit; then
                    status=supported
                    reason="repo has cached U2+L FPGA image and the image can build fresh ESP32-C3 artifacts"
                else
                    reason="u2pl_swonly needs cached u2p_ecp5_impl1.bit"
                fi
            else
                if [ "$IMAGE_HAS_RISCV" -eq 1 ] && [ "$IMAGE_HAS_LATTICE" -eq 1 ] && [ "$IMAGE_HAS_ESP32C3" -eq 1 ]; then
                    status=supported
                    reason="RISC-V, Lattice Diamond, and ESP32-C3 support are available"
                elif [ "$IMAGE_HAS_LATTICE" -ne 1 ]; then
                    reason="missing Lattice Diamond toolchain"
                elif [ "$IMAGE_HAS_ESP32C3" -ne 1 ]; then
                    reason="missing ESP32-C3 target support in ESP-IDF"
                else
                    reason="missing RISC-V toolchain"
                fi
            fi
            ;;
        u64)
            if [ "$IMAGE_HAS_NIOS" -eq 1 ] && [ "$IMAGE_HAS_QUARTUS" -eq 1 ] && [ "$IMAGE_HAS_ESP32" -eq 1 ]; then
                status=supported
                reason="Quartus, Nios, and ESP32 support are available"
            elif [ "$IMAGE_HAS_QUARTUS" -ne 1 ] || [ "$IMAGE_HAS_NIOS" -ne 1 ]; then
                reason="missing Quartus/Nios toolchain"
            else
                reason="missing ESP32 target support in ESP-IDF"
            fi
            ;;
        u64ii)
            if [ "$IMAGE_HAS_RISCV" -eq 1 ] && [ "$IMAGE_HAS_ESP32S3" -eq 1 ]; then
                status=supported
                reason="RISC-V and ESP32-S3 support are available"
            elif [ "$IMAGE_HAS_ESP32S3" -ne 1 ]; then
                reason="missing ESP32-S3 target support in ESP-IDF"
            else
                reason="missing RISC-V toolchain"
            fi
            ;;
        *)
            reason="unknown target"
            ;;
    esac

    _probe_line "$target" "$status" "$reason"
}

check_support() {
    local line target status reason
    local any_unsupported=0

    probe_image_capabilities
    printf 'Support check using image %s\n' "$DOCKER_IMAGE"
    if [ -n "$BUILD_TOOLS_DIR" ]; then
        printf 'Mounted build tools: %s\n' "$BUILD_TOOLS_DIR"
    else
        printf 'Mounted build tools: none\n'
    fi
    printf 'Mode: %s\n\n' "$([ "$SW_ONLY" -eq 1 ] && echo sw-only || echo full)"

    for target in "${TARGETS[@]}"; do
        line=$(probe_target_support "$target")
        status=${line#*|}; status=${status%%|*}
        reason=${line#*|*|}
        if [ "$status" = supported ]; then
            printf '  %s%-6s%s supported   %s\n' "$COLOR_GREEN" "$target" "$COLOR_RESET" "$reason"
        else
            any_unsupported=1
            printf '  %s%-6s%s unsupported %s\n' "$COLOR_RED" "$target" "$COLOR_RESET" "$reason"
        fi
    done

    return "$any_unsupported"
}
