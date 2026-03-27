#!/bin/bash
# =======================================================
# Triple-miner launch script v1.4
# -------------------------------------------------------
# xmrig    → 2x E5-2698 v4 CPUs (40 cores)  → XMR (RandomX)   @ CudoMiner
# t-rex    → 2x GTX 1080 8GB GPUs (~61 MH/s) → ETC (Etchash)  @ F2Pool
# boinc    → 2x Xeon Phi 5110p via MPSS      → GRC (BOINC)    @ grcpool
# -------------------------------------------------------
# Hardware: Supermicro SYS-2028GR-TR
# PCIe slots: 2x Phi 5110p (slots 1-2), 2x GTX 1080 8GB (slots 3-4)
# Estimated system draw: ~928W
#   2x E5-2698 v4        : ~270W
#   2x GTX 1080 8GB      : ~208W (~104W each)
#   2x Xeon Phi 5110p    : ~350W (~175W each at BOINC load)
#   Motherboard/RAM/NVMe : ~100W
# Requires: root, Ubuntu 20.04 LTS kernel 5.4 pinned, MPSS 3.8.6,
#           NVIDIA drivers, xmrig, t-rex, msr-tools
# =======================================================

# --------------------------
# xmrig — XMR via CudoMiner (RandomX, dual E5-2698 v4)
# Pays out in BTC to your CudoMiner account.
# NOTE: XMR_HOST contains hostname only — no protocol prefix.
#       The stratum+tcp:// prefix is applied in start_xmrig below.
#       Including the prefix here causes a doubled URL that xmrig
#       silently rejects, causing an infinite restart loop.
# --------------------------
XMR_HOST="stratum.cudopool.com"
XMR_PORT=30010
XMR_USER="o:account_id:n:worker_name"
XMR_PASS="x"
# 36 threads: leaves 2 physical cores free per socket for OS + MPSS overhead
# Tune upward to 40 if BOINC on Phi cards runs stably for 24+ hours
XMR_THREADS=36
XMRIG_MINER="./xmrig"

# --------------------------
# T-Rex — ETC via F2Pool (Etchash, 2x GTX 1080 8GB)
# F2Pool worker format: accountname.workername
# 2x GTX 1080 8GB @ ~30.55 MH/s each = ~61 MH/s combined @ ~208W
# DAG headroom: current ETC DAG is 4.09 GB — 8GB VRAM has ample headroom
# --------------------------
ETC_HOST="etc.f2pool.com"
ETC_PORT=8118
ETC_USER="f2pool_accountname.rig1"
ETC_PASS="x"
TREX_MINER="./t-rex"

# --------------------------
# BOINC — GRC via grcpool.com (2x Xeon Phi 5110p, MPSS native Linux)
# BOINC clients run directly on each card's native k1om Linux via MPSS.
# This script manages the host-side MPSS services and watchdog only.
# See phi-boinc-config-ubuntu2004.txt for full Phi card BOINC setup.
# --------------------------
BOINC_DATA_MIC0="/opt/phi-boinc/data/mic0"
BOINC_DATA_MIC1="/opt/phi-boinc/data/mic1"
BOINC_BIN="/opt/phi-boinc/mic/bin/boinc_client"
BOINC_CMD="/opt/phi-boinc/mic/bin/boinccmd"

# =======================================================
# End configuration — script body below
# =======================================================

# Root check — must be first, before touching any system resource
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root. MSR, huge-page, and MPSS setup require elevated privileges."
    exit 1
fi

LOGFILE="/var/log/phi-triple-miner.log"
touch "$LOGFILE"
chmod 640 "$LOGFILE"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

log "========== phi-triple-miner v1.4 starting =========="
log "Hardware: 2x E5-2698 v4 | 2x GTX 1080 8GB | 2x Phi 5110p"
log "Expected draw: ~928W"

# --------------------------
# Sanity checks — verify required binaries exist before proceeding.
# Prevents a missing binary causing a watchdog loop to spin at full
# speed filling the log with thousands of restart messages per hour.
# --------------------------
log "Checking required binaries..."
MISSING=0
for BIN in "$XMRIG_MINER" "$TREX_MINER" "$BOINC_BIN" "$BOINC_CMD"; do
    if [ ! -x "$BIN" ]; then
        log "ERROR: Required binary not found or not executable: $BIN"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    log "ABORT: One or more required binaries are missing. Correct paths and retry."
    exit 1
fi
log "All required binaries found."

# --------------------------
# MSR mod — disable Intel hardware prefetchers for RandomX.
# Gives ~10-15% hashrate improvement on Broadwell-EP (E5-2698 v4).
# Requires: msr.allow_writes=on in GRUB_CMDLINE_LINUX_DEFAULT.
# Also disable Hardware Prefetcher in BIOS for maximum effect.
# Register 0x1a4 bitmask:
#   bit 0 = L2 Hardware Prefetcher
#   bit 1 = L2 Adjacent Cache Line Prefetcher
#   bit 2 = DCU Prefetcher
#   bit 3 = DCU IP Prefetcher
# Value 15 (0xf) = all four disabled — xmrig default for Intel.
# Values 12 or 13 may be faster on Broadwell-EP — benchmark both.
# --------------------------
log "Applying MSR prefetcher disable for RandomX optimization..."
if modprobe msr 2>/dev/null; then
    CPU_COUNT=$(nproc --all)
    FAIL=0
    for CPU_ID in $(seq 0 $((CPU_COUNT - 1))); do
        if ! wrmsr -p "$CPU_ID" 0x1a4 0xf 2>/dev/null; then
            FAIL=1
        fi
    done
    if [ "$FAIL" -eq 0 ]; then
        log "MSR prefetcher registers set on all $CPU_COUNT logical CPUs."
    else
        log "WARNING: MSR writes partially failed."
        log "  Check: Secure Boot is off, and msr.allow_writes=on is in GRUB_CMDLINE_LINUX_DEFAULT"
    fi
else
    log "WARNING: MSR module unavailable."
    log "  Add msr.allow_writes=on to GRUB_CMDLINE_LINUX_DEFAULT then run: sudo update-grub"
fi

# --------------------------
# Huge page allocation — xmrig RandomX only.
# BOINC does not use huge pages. No GPU miner uses huge pages.
# Dual E5-2698 v4 (2 NUMA nodes): ~1,600 x 2MB pages per node.
# 3,700 total provides headroom across both NUMA nodes.
# --------------------------
log "Allocating 2MB huge pages for xmrig RandomX..."
if echo 3700 > /proc/sys/vm/nr_hugepages; then
    log "Huge pages: 3,700 x 2MB allocated (dual NUMA, xmrig only)."
else
    log "WARNING: Failed to allocate huge pages — xmrig RandomX will run slower."
fi

# 1GB huge pages — additional 1-3% RandomX boost where kernel supports it
if echo 4 > /proc/sys/vm/nr_hugepages_1g 2>/dev/null; then
    log "1GB huge pages: 4 pages allocated."
else
    log "INFO: 1GB huge pages unavailable on this kernel — skipping."
fi

# --------------------------
# MPSS health check — verify Phi cards are online before starting BOINC.
# Cards that are not online will cause boinc_client to fail silently
# on SSH connect. This check surfaces the failure explicitly and
# skips BOINC rather than spinning the watchdog against an offline card.
# --------------------------
log "Checking MPSS service and Phi card status..."
MPSS_OK=0
if ! systemctl is-active --quiet mpss; then
    log "WARNING: MPSS service is not running. Attempting to start..."
    if systemctl start mpss; then
        sleep 10
        log "MPSS started successfully."
        MPSS_OK=1
    else
        log "ERROR: MPSS failed to start. BOINC/GRC mining will be skipped."
    fi
else
    MPSS_OK=1
fi

# Verify both cards individually — one may be online while the other is not
if [ "$MPSS_OK" -eq 1 ]; then
    for CARD in mic0 mic1; do
        STATUS=$(micctrl --status "$CARD" 2>/dev/null | grep -i "online")
        if [ -z "$STATUS" ]; then
            log "WARNING: $CARD is not online — BOINC will not start on this card."
        else
            log "$CARD is online and ready."
        fi
    done
fi

# --------------------------
# Watchdog: xmrig (2x E5-2698 v4 — XMR RandomX @ CudoMiner)
# --randomx-numa-nodes 2: critical for dual-socket NUMA performance.
#   Without this flag xmrig treats both sockets as one flat memory
#   region, causing cross-NUMA memory latency that costs ~15% hashrate.
# --no-color: suppresses ANSI escape codes that clutter the log file.
# --log-file: appends to the shared log alongside BOINC and T-Rex output.
# --------------------------
start_xmrig() {
    log "Starting xmrig on 2x E5-2698 v4 — XMR via CudoMiner (RandomX)..."
    while true; do
        log "--- xmrig (re)starting ---"
        "$XMRIG_MINER" \
            --url "stratum+tcp://${XMR_HOST}:${XMR_PORT}" \
            --user "$XMR_USER" \
            --pass "$XMR_PASS" \
            -t "$XMR_THREADS" \
            --huge-pages \
            --randomx-numa-nodes 2 \
            --no-color \
            --log-file "$LOGFILE"
        log "xmrig exited ($?). Restarting in 10 seconds..."
        sleep 10
    done
}

# --------------------------
# Watchdog: T-Rex (2x GTX 1080 8GB — ETC Etchash @ F2Pool)
# --intensity 22: appropriate for GTX 1080 8GB GDDR5X.
#   Raised from 20 (1050 Ti default) — 1080 has more VRAM and
#   higher memory bandwidth to sustain the higher intensity safely.
#   If T-Rex reports memory errors, reduce to 21.
# --api-port 4067: exposes JSON API for XMRigCC monitoring dashboard.
# --no-color: clean log output.
# --------------------------
start_trex() {
    log "Starting T-Rex on 2x GTX 1080 8GB — ETC via F2Pool (Etchash)..."
    while true; do
        log "--- T-Rex (re)starting ---"
        "$TREX_MINER" \
            -a etchash \
            -o "stratum+tcp://${ETC_HOST}:${ETC_PORT}" \
            -u "$ETC_USER" \
            -p "$ETC_PASS" \
            --intensity 22 \
            --api-port 4067 \
            --no-color \
            --log-path "$LOGFILE"
        log "T-Rex exited ($?). Restarting in 10 seconds..."
        sleep 10
    done
}

# --------------------------
# Watchdog: BOINC on mic0 (Xeon Phi 5110p #1 — GRC via grcpool)
# boinc_client runs natively on the card's k1om Linux via MPSS NFS mount.
# SSH uses the dedicated key configured in phi-boinc-config-ubuntu2004.txt.
# Card-online check prevents SSH timeouts spinning the watchdog tight.
# --------------------------
start_boinc_mic0() {
    log "Starting BOINC client on mic0 (Phi 5110p #1) — GRC via grcpool..."
    while true; do
        if micctrl --status mic0 2>/dev/null | grep -qi "online"; then
            log "--- BOINC mic0 (re)starting ---"
            ssh -i /root/.ssh/id_mic \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
                root@mic0 \
                "$BOINC_BIN --daemon --data_dir $BOINC_DATA_MIC0" 2>&1 | \
                while read -r line; do log "[mic0] $line"; done
            log "BOINC mic0 exited ($?). Restarting in 30 seconds..."
            sleep 30
        else
            log "mic0 not online — waiting 60 seconds before retry..."
            sleep 60
        fi
    done
}

# --------------------------
# Watchdog: BOINC on mic1 (Xeon Phi 5110p #2 — GRC via grcpool)
# --------------------------
start_boinc_mic1() {
    log "Starting BOINC client on mic1 (Phi 5110p #2) — GRC via grcpool..."
    while true; do
        if micctrl --status mic1 2>/dev/null | grep -qi "online"; then
            log "--- BOINC mic1 (re)starting ---"
            ssh -i /root/.ssh/id_mic \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
                root@mic1 \
                "$BOINC_BIN --daemon --data_dir $BOINC_DATA_MIC1" 2>&1 | \
                while read -r line; do log "[mic1] $line"; done
            log "BOINC mic1 exited ($?). Restarting in 30 seconds..."
            sleep 30
        else
            log "mic1 not online — waiting 60 seconds before retry..."
            sleep 60
        fi
    done
}

# --------------------------
# Cleanup: kill entire process groups via setsid on SIGINT or SIGTERM.
# kill -- -PID signals the whole process group, reaching the miner
# binary itself — not just the watchdog shell loop. Without this,
# Ctrl+C kills the watchdog but orphans the running miner process.
# MSR registers are restored to default (0x0) on clean exit so the
# server behaves normally if used for other workloads between sessions.
# --------------------------
cleanup() {
    log "Shutdown signal received. Stopping all miners..."
    kill -- -"$XMR_PID"  2>/dev/null
    kill -- -"$ETC_PID"  2>/dev/null
    kill -- -"$MIC0_PID" 2>/dev/null
    kill -- -"$MIC1_PID" 2>/dev/null
    wait "$XMR_PID" "$ETC_PID" "$MIC0_PID" "$MIC1_PID" 2>/dev/null
    # Restore MSR prefetcher registers to hardware default
    if modprobe msr 2>/dev/null; then
        CPU_COUNT=$(nproc --all)
        for CPU_ID in $(seq 0 $((CPU_COUNT - 1))); do
            wrmsr -p "$CPU_ID" 0x1a4 0x0 2>/dev/null
        done
        log "MSR registers restored to default (0x0)."
    fi
    log "All miners stopped cleanly. Exiting."
    exit 0
}
trap cleanup SIGINT SIGTERM

# --------------------------
# Launch all miners as independent background process groups via setsid.
# setsid creates a new session for each watchdog so that kill -- -PID
# reaches all children in the group, not just the bash wrapper.
# Each block exports only the variables its function needs — prevents
# accidental cross-contamination between miner environments.
# --------------------------
setsid bash -c "
    $(declare -f start_xmrig log)
    LOGFILE='$LOGFILE'
    XMRIG_MINER='$XMRIG_MINER'
    XMR_HOST='$XMR_HOST'
    XMR_PORT='$XMR_PORT'
    XMR_USER='$XMR_USER'
    XMR_PASS='$XMR_PASS'
    XMR_THREADS='$XMR_THREADS'
    start_xmrig" &
XMR_PID=$!
log "xmrig watchdog started     — PID $XMR_PID  (XMR/RandomX @ CudoMiner)"

setsid bash -c "
    $(declare -f start_trex log)
    LOGFILE='$LOGFILE'
    TREX_MINER='$TREX_MINER'
    ETC_HOST='$ETC_HOST'
    ETC_PORT='$ETC_PORT'
    ETC_USER='$ETC_USER'
    ETC_PASS='$ETC_PASS'
    start_trex" &
ETC_PID=$!
log "T-Rex watchdog started     — PID $ETC_PID  (ETC/Etchash @ F2Pool)"

if [ "${MPSS_OK:-0}" -eq 1 ]; then
    setsid bash -c "
        $(declare -f start_boinc_mic0 log)
        LOGFILE='$LOGFILE'
        BOINC_BIN='$BOINC_BIN'
        BOINC_DATA_MIC0='$BOINC_DATA_MIC0'
        start_boinc_mic0" &
    MIC0_PID=$!
    log "BOINC mic0 watchdog started — PID $MIC0_PID (GRC @ grcpool)"

    setsid bash -c "
        $(declare -f start_boinc_mic1 log)
        LOGFILE='$LOGFILE'
        BOINC_BIN='$BOINC_BIN'
        BOINC_DATA_MIC1='$BOINC_DATA_MIC1'
        start_boinc_mic1" &
    MIC1_PID=$!
    log "BOINC mic1 watchdog started — PID $MIC1_PID (GRC @ grcpool)"
else
    log "MPSS unavailable — BOINC/GRC mining skipped. Check: systemctl status mpss"
    MIC0_PID=0
    MIC1_PID=0
fi

log "---------------------------------------------------"
log "  xmrig  (XMR) PID : $XMR_PID  | ~$(( XMR_THREADS * 1450 / 1000 )) kH/s est. (36 threads)"
log "  T-Rex  (ETC) PID : $ETC_PID  | ~61 MH/s est. (2x GTX 1080 8GB)"
log "  BOINC  (GRC) PIDs: mic0=$MIC0_PID mic1=$MIC1_PID | ~480 threads"
log "  System draw      : ~928W estimated"
log "  Log              : $LOGFILE"
log "  Stop             : Ctrl+C or: kill -TERM \$\$"
log "---------------------------------------------------"

# Hold the script open — wait for all background process groups
wait "$XMR_PID" "$ETC_PID" "$MIC0_PID" "$MIC1_PID"