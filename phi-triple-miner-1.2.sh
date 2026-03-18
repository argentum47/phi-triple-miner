#!/bin/bash
# =======================================================
# Triple-miner launch script v1.2.0
# -------------------------------------------------------
# xmrig    → 2x E5-2698 v4 CPUs (40 cores)  → XMR (RandomX)   @ cudominer
# t-rex    → 4x GTX 1050 Ti GPUs (~60 MH/s) → ETC (Etchash)   @ F2Pool
# boinc    → 2x Xeon Phi 5110p via MPSS      → GRC (BOINC)    @ grcpool
# -------------------------------------------------------
# Hardware: Supermicro SYS-2028GR-TR
# Estimated system draw: 1,110W+
# Requires: root privilege, MPSS 3.8.6, NVIDIA drivers, xmrig, t-rex
# =======================================================

# --------------------------
# xmrig — XMR via CudoMiner (RandomX, dual E5-2698 v4)
# pays out in BTC to your CudoMiner account
# --------------------------
XMR_HOST="cudominer.com"
XMR_PORT=xxxxxx
XMR_USER="your_XMR_wallet_address"
XMR_PASS="your_rig_name"
# 36 threads: leaves 2 physical cores free per socket for OS + MPSS overhead
XMR_THREADS=36
XMRIG_MINER="./xmrig"

# --------------------------
# T-Rex — ETC via F2Pool (Etchash, 4x GTX 1050ti)
# F2Pool worker format: accountname.workername
# 4x GTX 1050 Ti @ ~15 MH/s each = ~60 MH/s combined @ ~240W
# --------------------------
ETC_HOST="etc.f2pool.com"
ETC_PORT=8118
ETC_USER="your_f2pool_accountname.rig1"
ETC_PASS="x"
TREX_MINER="./t-rex"

# --------------------------
# BOINC — GRC via grcpool.com (2x Xeon Phi 5110p, MPSS native Linux)
# BOINC clients run directly on each card native k1om Linux via MPSS
# This script manages the host-side MPSS services only
# See phi-boinc-config.txt for full Phi card BOINC setup instructions
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

LOGFILE="/var/log/triple-miner.log"
touch "$LOGFILE"
chmod 640 "$LOGFILE"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

log "========== triple-miner v1.1.0 starting =========="

# --------------------------
# Sanity checks — verify required binaries exist before proceeding
# Prevents silent failures where a missing binary causes a watchdog
# loop to spin at maximum speed filling the log with restart messages
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
# MSR mod — disable Intel hardware prefetchers for RandomX
# Gives ~10-15% hashrate improvement on Broadwell-EP (E5-2698 v4)
# Requires: msr.allow_writes=on in GRUB_CMDLINE_LINUX_DEFAULT
# and also disable Hardware Prefetcher in BIOS for maximum effect.
# Register 0x1a4 bitmask: bit0=L2 HW, bit1=L2 Adjacent,
# bit2=DCU Prefetcher, bit3=DCU IP Prefetcher
# Value 15 = all four disabled (xmrig default)
# Values 12 or 13 may be faster on Broadwell — test both
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
        log "WARNING: MSR writes partially failed — check Secure Boot and kernel param msr.allow_writes=on"
    fi
else
    log "WARNING: MSR module unavailable. Add msr.allow_writes=on to GRUB_CMDLINE_LINUX_DEFAULT."
fi

# --------------------------
# Huge page allocation — xmrig RandomX only
# lukMiner removed in v1.1.0 (no viable CryptoNight Haven targets)
# BOINC does not use huge pages
# Dual E5-2698 v4 (2 NUMA nodes): ~1,600 pages per node = ~3,200 pages
# 3,700 total with buffer. Significantly reduced from v1.0.x (was 13,000)
# --------------------------
log "Allocating 2MB huge pages for xmrig RandomX..."
if echo 3700 > /proc/sys/vm/nr_hugepages; then
    log "Huge pages: 3,700 x 2MB allocated (dual NUMA, xmrig only)."
else
    log "WARNING: Failed to allocate huge pages — xmrig RandomX will run slower."
fi

# 1GB huge pages — additional 1-3% RandomX boost on supported kernels
if echo 4 > /proc/sys/vm/nr_hugepages_1g 2>/dev/null; then
    log "1GB huge pages: 4 pages allocated."
else
    log "INFO: 1GB huge pages unavailable on this kernel — skipping."
fi

# --------------------------
# MPSS health check — verify Phi cards are up before starting BOINC
# BOINC clients run on the card's native Linux; if MPSS is not running
# the cards are unreachable and boinc_client will fail silently
# --------------------------
log "Checking MPSS service and Phi card status..."
if ! systemctl is-active --quiet mpss; then
    log "WARNING: MPSS service is not running. Attempting to start..."
    if systemctl start mpss; then
        sleep 10   # Allow cards time to boot
        log "MPSS started."
    else
        log "ERROR: MPSS failed to start. BOINC/GRC mining will be skipped."
        MPSS_OK=0
    fi
else
    MPSS_OK=1
fi

# Verify both cards are online
if [ "$MPSS_OK" -eq 1 ]; then
    for CARD in mic0 mic1; do
        STATUS=$(micctrl --status "$CARD" 2>/dev/null | grep -i "online")
        if [ -z "$STATUS" ]; then
            log "WARNING: $CARD is not online — BOINC will not start on this card."
        else
            log "$CARD is online."
        fi
    done
fi

# --------------------------
# Watchdog: xmrig (2x E5-2698 v4 — XMR RandomX @ MoneroOcean)
# MoneroOcean auto-switches algorithm — no coin lock needed
# --randomx-numa-nodes 2: critical for dual-socket NUMA awareness
# --no-color: clean log output without ANSI escape sequences
# --------------------------
start_xmrig() {
    log "Starting xmrig on 2x E5-2698 v4 — XMR via MoneroOcean..."
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
# Watchdog: T-Rex (4x GTX 1050 Ti — ETC Etchash @ F2Pool)
# --intensity 20: safe default for 1050 Ti 4GB cards
# --api-port 4067: exposes local API for XMRigCC monitoring
# --------------------------
start_trex() {
    log "Starting T-Rex on 4x GTX 1050 Ti — ETC via F2Pool..."
    while true; do
        log "--- T-Rex (re)starting ---"
        "$TREX_MINER" \
            -a etchash \
            -o "stratum+tcp://${ETC_HOST}:${ETC_PORT}" \
            -u "$ETC_USER" \
            -p "$ETC_PASS" \
            --intensity 20 \
            --api-port 4067 \
            --no-color \
            --log-path "$LOGFILE"
        log "T-Rex exited ($?). Restarting in 10 seconds..."
        sleep 10
    done
}

# --------------------------
# Watchdog: BOINC on mic0 (Xeon Phi 5110p #1 — GRC via grcpool)
# boinc_client runs natively on the card's k1om Linux via MPSS NFS mount
# If mic0 is offline the loop waits and retries rather than spinning
# --------------------------
start_boinc_mic0() {
    log "Starting BOINC client on mic0 (Phi 5110p #1) — GRC via grcpool..."
    while true; do
        # Check card is online before attempting to start
        if micctrl --status mic0 2>/dev/null | grep -qi "online"; then
            log "--- BOINC mic0 (re)starting ---"
            ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@mic0 \
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
            ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@mic1 \
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
# Cleanup: send SIGTERM to entire process groups via setsid
# Using kill -- -PID reaches all children including miner binaries,
# not just the watchdog shell. Prevents orphaned miner processes
# on Ctrl+C or system shutdown.
# --------------------------
cleanup() {
    log "Shutdown signal received. Stopping all miners..."
    kill -- -"$XMR_PID"   2>/dev/null
    kill -- -"$ETC_PID"   2>/dev/null
    kill -- -"$MIC0_PID"  2>/dev/null
    kill -- -"$MIC1_PID"  2>/dev/null
    wait "$XMR_PID" "$ETC_PID" "$MIC0_PID" "$MIC1_PID" 2>/dev/null
    # Restore MSR prefetcher registers to original values on clean exit
    if modprobe msr 2>/dev/null; then
        CPU_COUNT=$(nproc --all)
        for CPU_ID in $(seq 0 $((CPU_COUNT - 1))); do
            wrmsr -p "$CPU_ID" 0x1a4 0x0 2>/dev/null
        done
        log "MSR registers restored."
    fi
    log "All miners stopped. Exiting."
    exit 0
}
trap cleanup SIGINT SIGTERM

# --------------------------
# Launch all miners as independent background process groups via setsid
# setsid creates a new session so kill -- -PID reaches the miner binary,
# not just the watchdog shell loop
# --------------------------
setsid bash -c "
    $(declare -f start_xmrig log)
    LOGFILE='$LOGFILE'
    XMRIG_MINER='$XMRIG_MINER'
    XMR_HOST='$XMR_HOST'; XMR_PORT='$XMR_PORT'
    XMR_USER='$XMR_USER'; XMR_PASS='$XMR_PASS'
    XMR_THREADS='$XMR_THREADS'
    start_xmrig" &
XMR_PID=$!
log "xmrig watchdog started    — PID $XMR_PID  (XMR/RandomX @ MoneroOcean)"

setsid bash -c "
    $(declare -f start_trex log)
    LOGFILE='$LOGFILE'
    TREX_MINER='$TREX_MINER'
    ETC_HOST='$ETC_HOST'; ETC_PORT='$ETC_PORT'
    ETC_USER='$ETC_USER'; ETC_PASS='$ETC_PASS'
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
    log "MPSS unavailable — BOINC/GRC mining skipped."
    MIC0_PID=0
    MIC1_PID=0
fi

log "---------------------------------------------------"
log "  xmrig  (XMR) PID : $XMR_PID  | ~$(( XMR_THREADS * 1450 / 1000 )) kH/s est."
log "  T-Rex  (ETC) PID : $ETC_PID  | ~60 MH/s est. (4x GTX 1050 Ti)"
log "  BOINC  (GRC) PIDs: mic0=$MIC0_PID mic1=$MIC1_PID | ~480 threads"
log "  Log   : $LOGFILE"
log "  Press Ctrl+C or send SIGTERM to stop all miners cleanly."
log "---------------------------------------------------"

# Hold the script open — wait for all background process groups
wait "$XMR_PID" "$ETC_PID" "$MIC0_PID" "$MIC1_PID"
