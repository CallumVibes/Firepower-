#!/system/bin/sh
# firepower.sh - Fire TV Stick tune-up
# Usage (from Remote ADB Shell):
#   sh /sdcard/Download/firepower.sh status      # overview (read-only)
#   sh /sdcard/Download/firepower.sh quick       # animations, caches, background apps (no apps disabled)
#   sh /sdcard/Download/firepower.sh clutter     # list Amazon extras and their state
#   sh /sdcard/Download/firepower.sh declutter <package>    # turn ONE off
#   sh /sdcard/Download/firepower.sh undeclutter <package>  # turn ONE back on
#   sh /sdcard/Download/firepower.sh restore     # undo everything FirePower changed
#   sh /sdcard/Download/firepower.sh net         # IP, DNS (Pi-hole check), Wi-Fi (read-only)
#   sh /sdcard/Download/firepower.sh hogs        # top memory users (read-only)
#   sh /sdcard/Download/firepower.sh diagnose 60 # log every 5s, N samples (read-only)
#   sh /sdcard/Download/firepower.sh startdiag 120 / stopdiag  # same, in background
#
# Safe with an existing update block:
# - quick never touches apps
# - declutter only disables apps on the approved list, one at a time, and logs them
# - undeclutter/restore only re-enable apps this script disabled
# - OTA/update packages are never touched, only reported in status

STATE=/sdcard/firepower.state
DIAG=/sdcard/firepower_diag.csv
DIAG_SH=/data/local/tmp/firepower_diag.sh

PKGS="com.amazon.device.crashmanager
com.amazon.logan
com.amazon.hedwig
com.amazon.bueller.photos"

# Read-only: shown in status so you can confirm your update block is intact
OTA_WATCH="com.amazon.device.software.ota
com.amazon.device.software.ota.override
com.amazon.tv.forcedotaupdater.v2"

ANIMS="window_animation_scale transition_animation_scale animator_duration_scale"

has()      { pm list packages "$1" 2>/dev/null | grep -qx "package:$1"; }
disabled() { pm list packages -d 2>/dev/null | grep -qx "package:$1"; }
state_of() {
  if ! has "$1"; then echo "not present"
  elif disabled "$1"; then echo "disabled"
  else echo "enabled"; fi
}
wifi_line() { dumpsys wifi | grep -m1 'mWifiInfo' | sed 's/[TR]x Link speed/xLink/g'; }

status() {
  echo "== Update block (never changed by this script) =="
  for p in $OTA_WATCH; do echo "$p: $(state_of $p)"; done
  echo "== Storage =="
  df -h /data | tail -1
  echo "== Memory =="
  grep -E 'MemTotal|MemAvailable' /proc/meminfo
  echo "== Animations =="
  for k in $ANIMS; do echo "$k: $(settings get global $k)"; done
  echo "== Clutter packages =="
  for p in $PKGS; do echo "$p: $(state_of $p)"; done
  echo "== Changes logged by this script =="
  [ -f "$STATE" ] && cat "$STATE" || echo "none"
  echo "== Wi-Fi link =="
  wifi_line | tr ',' '\n' | grep -E 'SSID|Link speed|Frequency|RSSI'
}

label_of() {
  case "$1" in
    com.amazon.device.crashmanager) echo "Crash reporting" ;;
    com.amazon.logan) echo "Usage logging" ;;
    com.amazon.hedwig) echo "Push notifications" ;;
    com.amazon.bueller.photos) echo "Amazon Photos" ;;
    *) echo "$1" ;;
  esac
}
in_list() { echo "$2" | grep -qx "$1"; }
ours()    { grep -qx "pkg:$1" "$STATE" 2>/dev/null; }

# 0.5 or faster (including 0 = off) counts as already set
is_fast() { case "$1" in 0|0.0*|0.[1-4]*|0.5|0.50) return 0 ;; *) return 1 ;; esac; }

# Zero-risk: never touches any app. Checks each setting before changing it.
quick() {
  echo "Animations:"
  for k in $ANIMS; do
    v=$(settings get global $k)
    if is_fast "$v"; then
      echo "  $k already $v, left alone"
    else
      grep -q "^anim:$k=" "$STATE" 2>/dev/null || echo "anim:$k=$v" >> "$STATE"
      settings put global $k 0.5
      echo "  $k: $v -> 0.5"
    fi
  done
  echo "Storage before: $(df -h /data | tail -1 | sed 's/  */ /g' | cut -d' ' -f4) free"
  echo "Clearing app caches..."
  pm trim-caches 999G
  echo "Closing background apps..."
  am kill-all
  echo "Storage after:  $(df -h /data | tail -1 | sed 's/  */ /g' | cut -d' ' -f4) free"
  echo "Done. No apps were disabled."
}

# Machine-readable list: package|label|enabled/disabled/absent|ours yes/no
clutter() {
  for p in $PKGS; do
    if ! has "$p"; then st=absent
    elif disabled "$p"; then st=disabled
    else st=enabled; fi
    if ours "$p"; then o=yes; else o=no; fi
    echo "$p|$(label_of "$p")|$st|$o"
  done
}

# Turn off ONE app from the approved list
declutter() {
  p="$1"
  if [ -z "$p" ] || ! in_list "$p" "$PKGS" || in_list "$p" "$OTA_WATCH"; then
    echo "Refused: '$p' is not on the declutter list."
    return 1
  fi
  if ! has "$p"; then echo "Not on this stick: $(label_of "$p")"; return 0; fi
  if disabled "$p"; then echo "Already off, left alone: $(label_of "$p")"; return 0; fi
  if pm disable-user --user 0 "$p" >/dev/null 2>&1 && disabled "$p"; then
    echo "pkg:$p" >> "$STATE"
    echo "Turned off: $(label_of "$p"). Restart the stick and check your apps."
  else
    echo "Blocked by Fire OS: $(label_of "$p")"
  fi
}

# Turn ONE app back on, only if FirePower turned it off
undeclutter() {
  p="$1"
  if [ -z "$p" ] || in_list "$p" "$OTA_WATCH"; then echo "Refused."; return 1; fi
  if ! ours "$p"; then echo "Not changed by FirePower, left alone: $(label_of "$p")"; return 1; fi
  if ! disabled "$p"; then
    grep -vx "pkg:$p" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
    echo "Already on, nothing to do: $(label_of "$p")"
    return 0
  fi
  pm enable "$p" >/dev/null 2>&1
  if disabled "$p"; then echo "Could not turn back on: $(label_of "$p")"; return 1; fi
  grep -vx "pkg:$p" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
  echo "Turned back on: $(label_of "$p")"
}

restore() {
  if [ ! -f "$STATE" ]; then echo "Nothing to restore."; return; fi
  grep '^anim:' "$STATE" | while IFS= read -r line; do
    kv=${line#anim:}; k=${kv%%=*}; v=${kv#*=}
    cur=$(settings get global "$k")
    if [ "$cur" != "0.5" ]; then
      echo "  $k changed since (now $cur), left alone"
    elif [ "$v" = "null" ]; then
      settings delete global "$k" >/dev/null; echo "  $k -> default"
    else
      settings put global "$k" "$v"; echo "  $k -> $v"
    fi
  done
  grep '^pkg:' "$STATE" | while IFS= read -r line; do
    p=${line#pkg:}
    if in_list "$p" "$OTA_WATCH"; then
      echo "  skipped (update package, left alone): $p"
    elif ! has "$p"; then
      echo "  not on this stick any more: $p"
    elif ! disabled "$p"; then
      echo "  already on, nothing to do: $(label_of "$p")"
    else
      pm enable "$p" >/dev/null 2>&1 && echo "  on: $(label_of "$p")"
    fi
  done
  rm -f "$STATE"
  echo "Restored only FirePower's changes. Restart the stick."
}

net() {
  echo "== IP address =="
  for i in wlan0 eth0; do
    a=$(ip -4 addr show "$i" 2>/dev/null | grep -o 'inet [0-9.]*')
    [ -n "$a" ] && echo "$i: ${a#inet }"
  done
  echo "== DNS servers (should be your Pi-hole's IP) =="
  dumpsys connectivity | grep -o 'DnsAddresses: \[[^]]*\]' | sort -u
  echo "== Private DNS (should be off or null, or Pi-hole is bypassed) =="
  settings get global private_dns_mode
  echo "== Wi-Fi =="
  wifi_line | tr ',' '\n' | grep -E 'SSID|Link speed|Frequency|RSSI'
  echo "(Frequency 5xxx = 5 GHz, 24xx = 2.4 GHz)"
}

hogs() {
  echo "== Top memory users =="
  dumpsys meminfo | sed -n '/Total PSS by process/,/^$/p' | head -16
}

diagnose() {
  n=${1:-60}
  echo "time,rssi_dbm,link_mbps,freq_mhz,mem_avail_kb,data_free_kb" > "$DIAG"
  echo "Logging $n samples, 5s apart, to $DIAG. Start playback now."
  i=0
  while [ "$i" -lt "$n" ]; do
    w=$(wifi_line)
    rssi=$(echo "$w" | sed -n 's/.*RSSI: \([-0-9]*\).*/\1/p')
    link=$(echo "$w" | sed -n 's/.*Link speed: \([0-9]*\).*/\1/p')
    freq=$(echo "$w" | sed -n 's/.*Frequency: \([0-9]*\).*/\1/p')
    mem=$(grep MemAvailable /proc/meminfo | sed 's/[^0-9]//g')
    free=$(df /data | tail -1 | sed 's/  */ /g' | cut -d' ' -f4)
    echo "$(date +%H:%M:%S),$rssi,$link,$freq,$mem,$free" | tee -a "$DIAG"
    i=$((i+1))
    sleep 5
  done
  echo "Done. Note the time of any stutter and compare with the log."
}

summary() {
  p=0; d=0
  for x in $OTA_WATCH; do
    if has "$x"; then
      p=$((p+1))
      disabled "$x" && d=$((d+1))
    fi
  done
  echo "ota_present=$p"
  echo "ota_disabled=$d"
  echo "storage_free=$(df -h /data | tail -1 | sed 's/  */ /g' | cut -d' ' -f4)"
  kb=$(grep MemAvailable /proc/meminfo | sed 's/[^0-9]//g')
  echo "mem_avail_mb=$(( ${kb:-0} / 1024 ))"
  w=$(wifi_line)
  echo "link_mbps=$(echo "$w" | sed -n 's/.*Link speed: \([-0-9]*\).*/\1/p')"
  echo "freq_mhz=$(echo "$w" | sed -n 's/.*Frequency: \([-0-9]*\).*/\1/p')"
  echo "rssi_dbm=$(echo "$w" | sed -n 's/.*RSSI: \([-0-9]*\).*/\1/p')"
  echo "anim=$(settings get global window_animation_scale)"
  echo "private_dns=$(settings get global private_dns_mode)"
}

stopdiag() {
  pkill -f 'firepower_diag.sh diagnose' && echo "Stopped." || echo "Not running."
}

startdiag() {
  if pgrep -f 'firepower_diag.sh diagnose' >/dev/null 2>&1; then
    echo "Already logging. Choose Diagnose results to see it so far."
    return 0
  fi
  rm -f "$DIAG"
  cp "$0" "$DIAG_SH"
  setsid nohup sh "$DIAG_SH" diagnose "${1:-120}" >/dev/null 2>&1 &
  echo "Logging started. Go and watch something."
}

case "${1:-status}" in
  status)   status ;;
  quick|boost) quick ;;
  clutter)  clutter ;;
  declutter) declutter "$2" ;;
  undeclutter) undeclutter "$2" ;;
  restore)  restore ;;
  net)      net ;;
  hogs)     hogs ;;
  diagnose) diagnose "$2" ;;
  summary)  summary ;;
  startdiag) startdiag "$2" ;;
  stopdiag) stopdiag ;;
  *) echo "Usage: sh firepower.sh [status|quick|clutter|declutter PKG|undeclutter PKG|restore|net|hogs|diagnose N|startdiag N|stopdiag|summary]" ;;
esac
