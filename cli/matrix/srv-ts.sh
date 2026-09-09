#!/bin/bash
# Start/stop the TypeScript conformance server (pidfile tracked). start <port>|stop
set -u
PIDFILE="/tmp/opencode/matrix/srv-ts.pid"; LOG="/tmp/opencode/matrix/srv-ts.log"
stop(){ if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi; }
start(){
  stop
  ( cd /home/user/easy-utils/easy-rpc-ts && npm run build >/dev/null 2>&1 )
  PORT="$PORT" setsid node /home/user/easy-utils/easy-rpc-ts/dist/srv.js >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && { exec 3<&-; return 0; }; sleep 0.2; done; return 0
}
case "${1:-start}" in start) start;; stop) stop;; esac
