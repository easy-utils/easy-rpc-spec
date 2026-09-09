#!/bin/bash
# Start/stop the Dart conformance server (pidfile tracked). start <port>|stop
set -u
PIDFILE="/tmp/opencode/matrix/srv-dart.pid"; LOG="/tmp/opencode/matrix/srv-dart.log"
stop(){ if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi; }
start(){
  stop
  ( cd /home/user/easy-utils/easy-rpc-dart && dart compile exe bin/conformance_server.dart -o /tmp/opencode/matrix/srv-dart >/dev/null 2>&1 )
  PORT="$PORT" setsid /tmp/opencode/matrix/srv-dart >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && { exec 3<&-; return 0; }; sleep 0.2; done; return 0
}
case "${1:-start}" in start) start;; stop) stop;; esac
