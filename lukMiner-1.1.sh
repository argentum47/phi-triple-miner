#!/bin/bash
# ====================================================================================
# LukMinerPhi launch script v1.1
# hardware  → SuperMicro SuperSuper rackmount 2u server SYS-2028GR-TR 
# lukMiner  → 4x Xeon Phi 5110p (x100)        → ZEPH (CryptoNight Haven) @ MiningOcean
# xmrig     → 2x E5-2698 v4 host CPUs         → XMR  (RandomX)           @ CudoPool
# t-rex     → 2x GTX 1070 Ti GPUs             → ETC  (Etchash)           @ F2Pool
# ====================================================================================
# Requires: root privilege for huge-page and MSR setup
# ====================================================================================

# ---------------------------------------------------------
# lukMiner — ZEPH via MiningOcean (algo: CryptoNight Haven)
# ---------------------------------------------------------
LUK_URL="pool.zephyr.miningocean.org"
LUK_PORT=1123
LUK_USER="your_ZEPH_wallet_address"
LUK_PASS="workername"
LUK_WATCHDOG=300
LUK_THREADS=-1
LUK_MINER="./luk-xmr-phi"

# ----------------------------------------
# xmrig — XMR via CudoPool (algo: RandomX)
# ----------------------------------------
XMR_HOST="stratum.cudopool.com"
XMR_PORT=30010
XMR_USER="your_XMR_wallet_address"
XMR_PASS="workername"
XMR_THREADS=20
XMRIG_MINER="./xmrig"

# --------------------------------------
# T-Rex — ETC via F2Pool (algo: Etchash)
# --------------------------------------
ETC_HOST="etc.f2pool.com"
ETC_PORT=8118
ETC_USER="accountname.workername"
ETC_PASS="x"
TREX_MINER="./t-rex"

# =======================================================
# End configuration — script body below
# =======================================================

# Root check
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root. Huge-page and MSR setup require elevated privileges."
    exit 1
fi

LOGFILE="/var/log/triple-miner.log"
touch "$LOGFILE"
chmod 640 "$LOGFILE"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# ---------------------------------------------------------------------------------
# MSR mod — disables hardware prefetchers for ~10-15% RandomX boost
# Requires msr.allow_writes=on kernel parameter (add to GRUB_CMDLINE_LINUX_DEFAULT)
# ---------------------------------------------------------------------------------
log "Applying MSR prefetcher disable for RandomX optimization..."
if modprobe msr 2>/dev/null; then
    # Intel Broadwell/Haswell: disable L2 HW prefetcher, L2 Adjacent, DCU prefetcher
    for cpu in /dev/cpu/*/msr; do
        wrmsr -p "${cpu//[^0-9]/}" 0x1a4 0xf 2>/dev/null
    done
    log "MSR prefetcher registers set successfully."
else
    log "WARNING: MSR module unavailable — RandomX running without prefetcher disable."
fi

# -----------------------------------------------------------
# Huge page allocation
# lukMiner : ~10000 x 2MB pages for 4x Phi cards
# xmrig    : ~3000  x 2MB pages for dual-NUMA E5-2698 v4 host
# Total    : 13000 with headroom
# ------------------------------------------------------------
log "Allocating 2MB huge pages..."
if ! echo 13000 > /proc/sys/vm/nr_hugepages; then
    log "WARNING: Failed to allocate huge pages — both miners will be slower."
else
    log "Huge pages: 13000 x 2MB allocated."
fi

# 1GB huge pages for xmrig — additional 1-3% RandomX boost
if echo 4 > /proc/sys/vm/nr_hugepages_1g 2>/dev/null; then
    log "1GB huge pages: 4 pages allocated for xmrig."
else
    log "INFO: 1GB huge pages unavailable on this kernel — skipping."
fi

# -------------------------------------
# Watchdog: lukMiner (Phi cards — ZEPH via MiningOcean)
# -------------------------------------
start_luk_miner() {
    log "Starting lukMiner on 4x Phi 5110p for ZEPH..."
    while true; do
        log "--- lukMiner (re)starting ---"
        "$LUK_MINER" \
            --url "$LUK_URL" \
            --port "$LUK_PORT" \
            --user "$LUK_USER" \
            --pass "$LUK_PASS" \
            -wd "$LUK_WATCHDOG" \
            -t "$LUK_THREADS"
        log "lukMiner exited ($?). Restarting in 5 seconds..."
        sleep 5
    done
}

# -----------------------------------------
# Watchdog: xmrig (Host CPUs — XMR RandomX)
# -----------------------------------------
start_xmrig() {
    log "Starting xmrig on 2x E5-2698v4 for XMR..."
    while true; do
        log "--- xmrig (re)starting ---"
        "$XMRIG_MINER" \
            --url "stratum+tcp://${XMR_HOST}:${XMR_PORT}" \
            --user "$XMR_USER" \
            --pass "$XMR_PASS" \
            -t "$XMR_THREADS" \
            --huge-pages \
            --randomx-numa-nodes 2 \
            --log-file "$LOGFILE" \
            --no-color
        log "xmrig exited ($?). Restarting in 5 seconds..."
        sleep 5
    done
}

# ---------------------------------------------------------
# Watchdog: T-Rex (GPUs x2 — ETC Etchash via F2Pool)
# ---------------------------------------------------------
start_trex() {
    log "Starting T-Rex on 2x GTX 1070ti for ETC via F2Pool..."
    while true; do
        log "--- T-Rex (re)starting ---"
        "$TREX_MINER" \
            -a etchash \
            -o "stratum+tcp://${ETC_HOST}:${ETC_PORT}" \
            -u "$ETC_USER" \
            -p "$ETC_PASS" \
            --log-path "$LOGFILE" \
            --no-color
        log "T-Rex exited ($?). Restarting in 5 seconds..."
        sleep 5
    done
}

# ---------------------------------------------------------------------
# Cleanup: kill entire process groups on Ctrl+C or SIGTERM
# Using negative PID to signal the whole group, not just the shell loop
# ---------------------------------------------------------------------
cleanup() {
    log "Shutdown signal received. Stopping all three miners..."
    kill -- -"$LUK_PID" 2>/dev/null
    kill -- -"$XMR_PID" 2>/dev/null
    kill -- -"$ETC_PID" 2>/dev/null
    wait "$LUK_PID" "$XMR_PID" "$ETC_PID" 2>/dev/null
    log "All miners stopped. Exiting."
    exit 0
}
trap cleanup SIGINT SIGTERM

# --------------------------------------------------------------------------
# Launch all three miners as independent background process groups
# setsid creates a new session so kill -- -PID reaches the miner binary too
# --------------------------------------------------------------------------
setsid bash -c "$(declare -f start_luk_miner log); LOGFILE=$LOGFILE; \
    LUK_MINER=$LUK_MINER; LUK_URL=$LUK_URL; LUK_PORT=$LUK_PORT; \
    LUK_USER=$LUK_USER; LUK_PASS=$LUK_PASS; LUK_WATCHDOG=$LUK_WATCHDOG; \
    LUK_THREADS=$LUK_THREADS; start_luk_miner" &
LUK_PID=$!
log "lukMiner watchdog started — PID $LUK_PID"

setsid bash -c "$(declare -f start_xmrig log); LOGFILE=$LOGFILE; \
    XMRIG_MINER=$XMRIG_MINER; XMR_HOST=$XMR_HOST; XMR_PORT=$XMR_PORT; \
    XMR_USER=$XMR_USER; XMR_PASS=$XMR_PASS; XMR_THREADS=$XMR_THREADS; \
    start_xmrig" &
XMR_PID=$!
log "xmrig watchdog started — PID $XMR_PID"

setsid bash -c "$(declare -f start_trex log); LOGFILE=$LOGFILE; \
    TREX_MINER=$TREX_MINER; ETC_HOST=$ETC_HOST; ETC_PORT=$ETC_PORT; \
    ETC_USER=$ETC_USER; ETC_PASS=$ETC_PASS; start_trex" &
ETC_PID=$!
log "T-Rex watchdog started — PID $ETC_PID"

log "All three miners running."
log "  lukMiner (ZEPH) PID : $LUK_PID"
log "  xmrig    (XMR)  PID : $XMR_PID"
log "  T-Rex    (ETC)  PID : $ETC_PID"
log "Press Ctrl+C or send SIGTERM to stop all miners cleanly."

wait "$LUK_PID" "$XMR_PID" "$ETC_PID"