#!/usr/bin/env bash
set -uo pipefail

IPERF_HOST="${IPERF_HOST:?not set}"
IPERF_PORT="${IPERF_PORT:-5201}"
IPERF_TIME="${IPERF_TIME:-10}"
IPERF_PARALLEL="${IPERF_PARALLEL:-4}"
INTERVAL="${INTERVAL:-600}"
PUSHGATEWAY="${PUSHGATEWAY:-http://pushgateway:9091}"
JOB="${JOB:-iperf3}"
INSTANCE="${INSTANCE:-vps}"

URL="${PUSHGATEWAY}/metrics/job/${JOB}/instance/${INSTANCE}"

log() { echo "[$(date -Is)] $*"; }

push() {
  curl -s --max-time 10 --data-binary @- "$URL" >/dev/null \
    && log "pushed ok" || log "push FAILED"
}

measure() {
  local direction="$1" extra="$2" out rc
  out=$(iperf3 -c "$IPERF_HOST" -p "$IPERF_PORT" -t "$IPERF_TIME" \
        -P "$IPERF_PARALLEL" -J --connect-timeout 5000 $extra 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    log "$direction: iperf3 failed (rc=$rc)"
    return 1
  fi
  if echo "$out" | jq -e '.error' >/dev/null 2>&1; then
    log "$direction: $(echo "$out" | jq -r '.error')"
    return 1
  fi
  echo "$out"
}

run_once() {
  local up_json down_json up_bps down_bps up_rtx down_rtx ok=1

  log "measuring upload..."
  if up_json=$(measure upload ""); then
    up_bps=$(echo "$up_json"   | jq -r '.end.sum_received.bits_per_second')
    up_rtx=$(echo "$up_json"   | jq -r '.end.sum_sent.retransmits // 0')
  else
    ok=0
  fi

  sleep 5

  log "measuring download..."
  if down_json=$(measure download "-R"); then
    down_bps=$(echo "$down_json" | jq -r '.end.sum_received.bits_per_second')
    down_rtx=$(echo "$down_json" | jq -r '.end.sum_sent.retransmits // 0')
  else
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    log "up=$(printf '%.1f' "$(echo "$up_bps/1000000" | bc -l)") Mbit/s  down=$(printf '%.1f' "$(echo "$down_bps/1000000" | bc -l)") Mbit/s"
    cat <<EOF | push
# TYPE iperf3_upload_bits_per_second gauge
# HELP iperf3_upload_bits_per_second Upload throughput measured by iperf3
iperf3_upload_bits_per_second $up_bps
# TYPE iperf3_download_bits_per_second gauge
# HELP iperf3_download_bits_per_second Download throughput measured by iperf3
iperf3_download_bits_per_second $down_bps
# TYPE iperf3_upload_retransmits gauge
iperf3_upload_retransmits $up_rtx
# TYPE iperf3_download_retransmits gauge
iperf3_download_retransmits $down_rtx
# TYPE iperf3_up gauge
# HELP iperf3_up 1 if last measurement succeeded
iperf3_up 1
# TYPE iperf3_last_run_timestamp_seconds gauge
iperf3_last_run_timestamp_seconds $(date +%s)
EOF
  else
    cat <<EOF | push
# TYPE iperf3_up gauge
iperf3_up 0
# TYPE iperf3_last_run_timestamp_seconds gauge
iperf3_last_run_timestamp_seconds $(date +%s)
EOF
  fi
}

log "started: host=$IPERF_HOST:$IPERF_PORT interval=${INTERVAL}s parallel=$IPERF_PARALLEL"

while true; do
  run_once
  now=$(date +%s)
  sleep $(( INTERVAL - (now % INTERVAL) ))
done
