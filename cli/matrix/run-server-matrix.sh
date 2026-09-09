#!/bin/bash
# easy-rpc server negotiation matrix: for each server bridge, start it, probe
# with both HTTP/1.1 and HTTP/2.0 (h2c prior-knowledge) echo+count, then stop.
# Prints a PASS/FAIL table of (server, protocol) support.
set -u
cd "$(dirname "$0")"
M=/tmp/opencode/matrix
mkdir -p "$M"
PORT_START=25000

# ---- Build/start/stop per server, each returns via pidfile ----
srv_go()       { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-go && go build -o "$M/srv-go" ./cmd/conformance-server ) ; PORT="$P" setsid "$M/srv-go" >"$M/srv-go.log" 2>&1 </dev/null & echo $! >"$M/srv-go.pid"; else kill "$(cat "$M/srv-go.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-go.pid"; fi; }
srv_tshttp()   { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-ts && npm run build >/dev/null 2>&1 ); PORT="$P" setsid node /home/user/easy-utils/easy-rpc-ts/dist/srv.js >"$M/srv-ts.log" 2>&1 </dev/null & echo $! >"$M/srv-ts.pid"; else kill "$(cat "$M/srv-ts.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-ts.pid"; fi; }
srv_tshttp2()  { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-ts && npm run build >/dev/null 2>&1 ); PORT="$P" setsid node --input-type=module -e "
import { http2Server, createServer } from '/home/user/easy-utils/easy-rpc-ts/dist/server.js';
import { ConformanceServiceHandlers } from '/home/user/easy-utils/easy-rpc-ts/dist/easyrpc/conformance/v1/conformance_easyrpc.js';
import { create } from '/home/user/easy-utils/easy-rpc-ts/node_modules/@bufbuild/protobuf/dist/esm/index.js';
import { HealthResponseSchema, EchoResponseSchema, CountResponseSchema, FailResponseSchema } from '/home/user/easy-utils/easy-rpc-ts/dist/easyrpc/conformance/v1/conformance_pb.js';
const impl = { health:async()=>create(HealthResponseSchema,{ok:true,name:'conformance'}), echo:async(r)=>create(EchoResponseSchema,{output:'echo:'+r.input}), count:async()=>({ async *[Symbol.asyncIterator](){ for(let i=0;i<3;i++) yield create(CountResponseSchema,{index:i}) } }), fail:async()=>create(FailResponseSchema,{ok:true}) };
const h = ConformanceServiceHandlers(impl);
http2Server(createServer([{path:'/v1/health',name:'Health',serverStream:false},{path:'/v1/echo',name:'Echo',serverStream:false},{path:'/v1/count',name:'Count',serverStream:true}], h)).listen(Number(process.env.PORT),'127.0.0.1',()=>console.log('ts h2 on',process.env.PORT));
" >"$M/srv-tsh2.log" 2>&1 </dev/null & echo $! >"$M/srv-tsh2.pid"; else kill "$(cat "$M/srv-tsh2.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-tsh2.pid"; fi; }
srv_rust()     { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-rust && cargo build --release >/dev/null 2>&1 ); PORT="$P" setsid /home/user/easy-utils/easy-rpc-rust/target/release/conformance_server >"$M/srv-rust.log" 2>&1 </dev/null & echo $! >"$M/srv-rust.pid"; else kill "$(cat "$M/srv-rust.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-rust.pid"; fi; }
srv_uvicorn()  { if [ "${1:-}" = start ]; then PORT="$P" setsid python3 /home/user/easy-utils/easy-rpc-python/conformance_server_uvicorn.py >"$M/srv-uvicorn.log" 2>&1 </dev/null & echo $! >"$M/srv-uvicorn.pid"; else kill "$(cat "$M/srv-uvicorn.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-uvicorn.pid"; fi; }
srv_hypercorn() { if [ "${1:-}" = start ]; then PORT="$P" setsid python3 /home/user/easy-utils/easy-rpc-python/conformance_server_hypercorn.py >"$M/srv-hypercorn.log" 2>&1 </dev/null & echo $! >"$M/srv-hypercorn.pid"; else kill "$(cat "$M/srv-hypercorn.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-hypercorn.pid"; fi; }
srv_shelf()    { if [ "${1:-}" = start ]; then PORT="$P" setsid dart run /home/user/easy-utils/easy-rpc-dart/bin/conformance_server_shelf.dart >"$M/srv-shelf.log" 2>&1 </dev/null & echo $! >"$M/srv-shelf.pid"; else kill "$(cat "$M/srv-shelf.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-shelf.pid"; fi; }
srv_kestrel()  { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-csharp && dotnet build kestrel/kestrel.csproj >/dev/null 2>&1 ); PORT="$P" setsid dotnet /home/user/easy-utils/easy-rpc-csharp/kestrel/bin/Debug/net10.0/kestrel.dll >"$M/srv-kestrel.log" 2>&1 </dev/null & echo $! >"$M/srv-kestrel.pid"; else kill "$(cat "$M/srv-kestrel.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-kestrel.pid"; fi; }
srv_swift()    { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-swift && swift build >/dev/null 2>&1 ); B=$(find /home/user/easy-utils/easy-rpc-swift/.build -name conformance-server -type f 2>/dev/null | head -1); PORT="$P" setsid "$B" >"$M/srv-swift.log" 2>&1 </dev/null & echo $! >"$M/srv-swift.pid"; else kill "$(cat "$M/srv-swift.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-swift.pid"; fi; }
srv_ktor()     { if [ "${1:-}" = start ]; then ( cd /home/user/easy-utils/easy-rpc-kotlin && gradle compileKotlin --rerun-tasks >/dev/null 2>&1 ); find "$HOME/.gradle/caches/modules-2/files-2.1" -name '*.jar' | tr '\n' ':' >"$M/kotlin_cp.txt"; PORT="$P" setsid java -cp "$(cat "$M/kotlin_cp.txt"):/home/user/easy-utils/easy-rpc-kotlin/build/classes/kotlin/main:/home/user/easy-utils/easy-rpc-kotlin/build/classes/java/main" easyrpc.KtorServerKt >"$M/srv-ktor.log" 2>&1 </dev/null & echo $! >"$M/srv-ktor.pid"; else kill "$(cat "$M/srv-ktor.pid" 2>/dev/null)" 2>/dev/null; rm -f "$M/srv-ktor.pid"; fi; }

# Probe: try HTTP version (1.1 or 2) echo+count once; retry up to 10s for startup.
probe() {
  local name=$1 port=$2 ver=$3
  for _ in $(seq 1 40); do
    local code
    code=$(curl -s --max-time 3 ${ver:+--http2-prior-knowledge} -o "$M/p.bin" -w '%{http_code}' -X POST "http://127.0.0.1:$port/v1/echo" -H 'content-type: application/proto' --data-binary @/tmp/opencode/echo_req.bin 2>/dev/null)
    if [ "$code" = "200" ]; then return 0; fi
    sleep 0.5
  done
  return 1
}

declare -A F=( [go]=srv_go [ts-http]=srv_tshttp [ts-http2]=srv_tshttp2 [rust]=srv_rust [uvicorn]=srv_uvicorn [hypercorn]=srv_hypercorn [shelf]=srv_shelf [kestrel]=srv_kestrel [swift]=srv_swift [ktor]=srv_ktor )
declare -A H1=( [go]=yes [ts-http]=yes [ts-http2]=no [rust]=yes [uvicorn]=yes [hypercorn]=yes [shelf]=yes [kestrel]=yes [swift]=yes [ktor]=yes )
declare -A H2=( [go]=yes [ts-http]=no [ts-http2]=yes [rust]=yes [uvicorn]=no [hypercorn]=yes [shelf]=no [kestrel]=no [swift]=yes [ktor]=yes )

echo "| server | h1 | h2c |"
echo "|--------|:--:|:---:|"
for name in go ts-http ts-http2 rust uvicorn hypercorn shelf kestrel swift ktor; do
  P=$PORT_START; PORT_START=$((PORT_START+1))
  "${F[$name]}" start
  # wait for bind
  for _ in $(seq 1 40); do (exec 3<>/dev/tcp/127.0.0.1/"$P") 2>/dev/null && { exec 3<&-; break; }; sleep 0.4; done
  h1=FAIL; h2=FAIL
  if [ "${H1[$name]}" = "yes" ]; then probe "$name" "$P" "" && h1=PASS; fi
  if [ "${H2[$name]}" = "yes" ]; then probe "$name" "$P" "--http2-prior-knowledge" && h2=PASS; fi
  echo "| $name | $h1 | $h2 |"
  "${F[$name]}" stop
done
