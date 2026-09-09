#!/bin/bash
# Start/stop the C# conformance server (pidfile tracked). start <port>|stop
set -u
PIDFILE="/tmp/opencode/matrix/srv-csharp.pid"; LOG="/tmp/opencode/matrix/srv-csharp.log"
stop(){ if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi; }
start(){
  stop
  ( cd /home/user/easy-utils/easy-rpc-csharp && rm -rf obj bin server/obj server/bin tests/obj tests/bin && dotnet build server/server.csproj >/dev/null 2>&1 )
  PORT="$PORT" setsid dotnet /home/user/easy-utils/easy-rpc-csharp/server/bin/Debug/net10.0/server.dll >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && { exec 3<&-; return 0; }; sleep 0.2; done; return 0
}
case "${1:-start}" in start) start;; stop) stop;; esac
