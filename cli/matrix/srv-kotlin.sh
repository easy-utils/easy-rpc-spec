#!/bin/bash
# Start/stop the Kotlin conformance server (pidfile tracked). start <port>|stop
set -u
PIDFILE="/tmp/opencode/matrix/srv-kotlin.pid"; LOG="/tmp/opencode/matrix/srv-kotlin.log"
KT_DIR="/home/user/easy-utils/easy-rpc-kotlin"
CP="/tmp/opencode/matrix/kotlin_cp.txt"
stop(){ if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi; }
start(){
  stop
  ( cd "$KT_DIR" && gradle compileKotlin --rerun-tasks >/dev/null 2>&1 )
  PORT="$PORT" setsid java -cp "$(cat "$CP"):$KT_DIR/build/classes/kotlin/main:$KT_DIR/build/classes/java/main" easyrpc.ConformanceServerKt >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && { exec 3<&-; return 0; }; sleep 0.2; done; return 0
}
case "${1:-start}" in start) start;; stop) stop;; esac
