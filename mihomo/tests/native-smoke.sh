#!/usr/bin/env bash
# Exercise an already-built, UNPUBLISHED native candidate with real Node/Mihomo.
# No downloads/builds, systemd operations or Docker mutations. Only loopback
# listeners and module-local disposable data are used. Run with sudo in CI.
set -Eeuo pipefail
umask 077
fail() { printf 'Native smoke failed: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] && [[ "$1" = /* ]] || fail 'Usage: native-smoke.sh ABSOLUTE_BUILT_RELEASE'
[ "$(id -u)" -eq 0 ] || fail 'Run with sudo so the real launcher can apply its config permissions'
for command_name in setsid ps awk sha256sum flock readlink; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Missing $command_name"
done
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE="$HERE/../deploy"
RELEASE="$(readlink -f -- "$1")"
RUNTIME="$(cd -- "$RELEASE/../.." && pwd -P)"
[ "$(basename -- "$RUNTIME")" = host ] && [ "$(basename -- "$(dirname -- "$RUNTIME")")" = runtime ] ||
    fail 'Candidate must have the native builder runtime layout'
[ "$(basename -- "$(dirname -- "$RELEASE")")" != releases ] ||
    fail 'Use an unpublished staging candidate; installed release directories are immutable'
if [ -L "$RUNTIME/current" ] && [ "$(readlink -f -- "$RUNTIME/current")" = "$RELEASE" ]; then
    fail 'Refusing to modify the selected runtime release'
fi
NODE="$RELEASE/node/bin/node"
[ -x "$NODE" ] && [ -x "$RELEASE/mihomo" ] && [ -f "$RELEASE/server/index.mjs" ] &&
    [ -f "$RELEASE/ui-dist/index.html" ] && [ -f "$RELEASE/node_modules/yaml/package.json" ] ||
    fail 'Complete built candidate required'
exec 9>"$RELEASE/.native-smoke.lock"
flock -n 9 || fail 'Another smoke test is already using this candidate'
mkdir -p "$RELEASE/launch"
for launch_file in host-run.sh host-kernel.sh host-config.mjs common.sh host-health.mjs; do
    cp -- "$SOURCE/$launch_file" "$RELEASE/launch/$launch_file"
done
chmod 0700 "$RELEASE/launch/host-run.sh" "$RELEASE/launch/host-kernel.sh"

work="$(mktemp -d "$RUNTIME/.native-smoke.XXXXXXXX")"
TEST_ROOT="$work/software"
TEST_MODULE="$TEST_ROOT/mihomo"
TEST_DATA="$TEST_MODULE/data/all-in-one"
INPUT="$TEST_MODULE/runtime/host/test-input"
REPORT="$RUNTIME/smoke-reports/${work##*/}"
mkdir -p "$TEST_ROOT/deploy/lib" "$TEST_DATA/profiles" "$INPUT" "$work/logs" "$REPORT"
cp "$HERE/../../lib/platform.sh" "$TEST_ROOT/deploy/lib/platform.sh"
cp -- "$RELEASE/versions.txt" "$REPORT/versions.txt"
phase=prepare
core_launcher="" core_group="" agent_launcher="" agent_group=""
started_seconds=$SECONDS
export SMOKE_WORK="$work" SMOKE_MODULE="$TEST_MODULE" SMOKE_RELEASE="$RELEASE"
export SMOKE_REPORT="$REPORT"
# These are disposable fixture values, never user credentials. Keep them out
# of stdout, arguments and published artifacts, including on assertion failure.
export SMOKE_ASCII_SECRET='native-smoke :# "quoted" token'
export SMOKE_UNICODE_SECRET='原生烟雾测试 :# "quoted" 密钥'
export CONTROL_TOKEN='native-smoke-control-fixture'
export SMOKE_PROXY_USER='smoke-user'
export SMOKE_PROXY_PASSWORD='native proxy :# "quoted" pass'
export CLASH_SECRET="$SMOKE_ASCII_SECRET"

cat > "$work/check.mjs" <<'EOF_HELPER'
import fs from 'node:fs'
import path from 'node:path'
import net from 'node:net'
import http from 'node:http'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const root = process.env.SMOKE_WORK
const moduleDir = process.env.SMOKE_MODULE
const data = path.join(moduleDir, 'data/all-in-one')
const input = path.join(moduleDir, 'runtime/host/test-input')
class SmokeFailure extends Error {}
const check = (ok, message) => { if (!ok) throw new SmokeFailure(message) }
const auth = () => Buffer.from(`Bearer ${process.env.CLASH_SECRET}`, 'utf8').toString('latin1')
async function request(port, pathname, headers = {}, method = 'GET') {
  return await new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port, path: pathname, method,
      headers, signal: AbortSignal.timeout(4000), agent: false }, (res) => {
      const chunks = []
      res.on('data', (chunk) => chunks.push(chunk))
      res.on('error', reject)
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }))
    })
    req.on('error', reject)
    req.end()
  })
}
function json(response, label) {
  check(response.status === 200, `${label} did not return HTTP 200`)
  try { return JSON.parse(response.text) } catch { throw new SmokeFailure(`${label} did not return JSON`) }
}
const corePort = () => Number(process.env.MIHOMO_CORE_API_PORT)
try {
  const command = process.argv[2]
  if (command === 'ports') {
    const servers = []
    try {
      for (let i = 0; i < 5; i++) {
        const server = net.createServer()
        servers.push(server)
        await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve) })
      }
      const ports = servers.map((server) => server.address().port)
      check(ports.every((port) => port > 1024) && new Set(ports).size === 5, 'Loopback high-port allocation failed')
      console.log(ports.join(' '))
    } finally {
      await Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve))))
    }
  } else if (command === 'prepare') {
    const YAML = require(path.join(process.env.SMOKE_RELEASE, 'node_modules/yaml'))
    const profile = '---\n' + YAML.stringify({
      'mixed-port': 7890,
      'external-controller': '0.0.0.0:9090',
      'mode': 'rule', 'log-level': 'warning', 'ipv6': false,
      'dns': { enable: false },
      // Explicitly exercise authentication even for this loopback-only fixture.
      // https://wiki.metacubex.one/en/config/general/#user-authentication
      'authentication': [`${process.env.SMOKE_PROXY_USER}:${process.env.SMOKE_PROXY_PASSWORD}`],
      'skip-auth-prefixes': [],
      'proxies': [{ name: 'SmokeNode', type: 'http', server: '127.0.0.1', port: 9 }],
      'proxy-groups': [{ name: 'SmokeGroup', type: 'select', proxies: ['DIRECT', 'SmokeNode'] }],
      'rules': ['DOMAIN,smoke.invalid,SmokeGroup', 'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve', 'MATCH,DIRECT'],
    })
    const managed = (secret) => `external-controller: 0.0.0.0:9090\nsecret: ${secret}\nmixed-port: 7890\n${profile}`
    fs.writeFileSync(path.join(input, 'profile.yaml'), profile)
    fs.writeFileSync(path.join(input, 'docker-active-ascii.yaml'), managed(process.env.SMOKE_ASCII_SECRET))
    fs.writeFileSync(path.join(input, 'docker-active-unicode.yaml'), managed(process.env.SMOKE_UNICODE_SECRET))
    fs.writeFileSync(path.join(data, 'profiles/smoke-profile.yaml'), profile)
    fs.writeFileSync(path.join(data, 'profiles/index.json'), JSON.stringify([
      { id: 'smoke-profile', name: 'Native smoke fixture', type: 'local', updatedAt: 0 },
    ]) + '\n')
    fs.writeFileSync(path.join(data, 'profiles/state.json'), '{"activeId":"smoke-profile"}\n')
    fs.copyFileSync(path.join(input, 'docker-active-ascii.yaml'), path.join(data, 'active.yaml'))
    const config = path.join(root, 'software/deploy')
    fs.writeFileSync(path.join(config, '.env'), [
      `MIHOMO_MIXED_PORT=${process.env.AGENT_MIXED_PORT}`,
      `MIHOMO_API_PORT=${process.env.AGENT_WEB_PORT}`,
      `MIHOMO_CORE_API_PORT=${process.env.AGENT_CORE_PORT}`,
      'MIHOMO_PROXY_BIND_IP=127.0.0.1', 'MIHOMO_API_BIND_IP=127.0.0.1',
      'MIHOMO_CORE_API_BIND_IP=127.0.0.1', 'TZ=Asia/Shanghai', '',
    ].join('\n'))
    fs.writeFileSync(path.join(config, '.secrets'), [
      `MIHOMO_API_SECRET=${process.env.SMOKE_ASCII_SECRET}`,
      `MIHOMO_CONTROL_TOKEN=${process.env.CONTROL_TOKEN}`, '',
    ].join('\n'))
  } else if (command === 'probe') {
    const version = json(await request(corePort(), '/version', { Authorization: auth() }), 'Core version')
    check(typeof version.version === 'string', 'Core version response is invalid')
  } else if (command === 'verify') {
    const headers = { Authorization: auth() }
    const proxies = json(await request(corePort(), '/proxies', headers), 'Core proxies').proxies
    check(proxies?.SmokeNode && proxies?.SmokeGroup, 'Native conversion lost the named node/group')
    check(proxies.SmokeGroup.all?.includes('SmokeNode') && proxies.SmokeGroup.all.includes('DIRECT'), 'Proxy group membership changed')
    const rules = json(await request(corePort(), '/rules', headers), 'Core rules').rules
    check(Array.isArray(rules) && rules.some((r) => r.payload === 'smoke.invalid' && r.proxy === 'SmokeGroup'), 'Domain rule was lost')
    check(rules.some((r) => r.payload === '127.0.0.0/8' && r.proxy === 'DIRECT'), 'Loopback rule was lost')
    check(rules.some((r) => String(r.type).toLowerCase() === 'match' && r.proxy === 'DIRECT'), 'Fallback rule was lost')
    const rejected = await request(corePort(), '/version')
    check(rejected.status === 401, 'Core API unexpectedly accepted a missing secret')
    const target = http.createServer((_req, res) => { res.writeHead(200, { 'content-type': 'text/plain' }); res.end('native-smoke-local-only') })
    try {
      await new Promise((resolve, reject) => { target.once('error', reject); target.listen(0, '127.0.0.1', resolve) })
      const destination = `http://127.0.0.1:${target.address().port}/native-smoke`
      // An HTTP proxy request carries the destination Host, not the address
      // of the proxy socket; Node otherwise defaults to the latter.
      const destinationHeaders = { Host: new URL(destination).host }
      const proxyPort = Number(process.env.MIHOMO_MIXED_PORT)
      const denied = await request(proxyPort, destination, destinationHeaders)
      check(denied.status === 407, `Proxy authentication was lost: expected HTTP 407, got ${denied.status}`)
      const credentials = Buffer.from(`${process.env.SMOKE_PROXY_USER}:${process.env.SMOKE_PROXY_PASSWORD}`, 'utf8').toString('base64')
      const allowed = await request(proxyPort, destination, { ...destinationHeaders, 'Proxy-Authorization': `Basic ${credentials}` })
      check(allowed.status === 200 && allowed.text === 'native-smoke-local-only',
        `Configured proxy authentication was not preserved (status=${allowed.status}, body_bytes=${Buffer.byteLength(allowed.text)})`)
    } finally { await new Promise((resolve) => target.close(resolve)) }
  } else if (command === 'stop-agent') {
    const response = await request(Number(process.env.AGENT_WEB_PORT), '/api/control/kernel/stop',
      { Authorization: `Bearer ${process.env.CONTROL_TOKEN}` }, 'POST')
    check(response.status === 200, 'Agent stop request failed')
  } else if (command === 'ports-closed') {
    const ports = process.argv.slice(3).map(Number)
    for (const port of ports) {
      const connected = await new Promise((resolve) => {
        const socket = net.connect({ host: '127.0.0.1', port })
        socket.once('connect', () => { socket.destroy(); resolve(true) })
        socket.once('error', () => resolve(false))
        socket.setTimeout(1000, () => { socket.destroy(); resolve(false) })
      })
      check(!connected, 'A smoke-test listener survived process cleanup')
    }
  } else if (command === 'summary') {
    const report = process.env.SMOKE_REPORT
    const checks = fs.existsSync(path.join(report, 'checks.tsv'))
      ? fs.readFileSync(path.join(report, 'checks.tsv'), 'utf8').trim().split('\n').filter(Boolean).map((line) => line.split('\t').slice(1).join('\t')) : []
    fs.writeFileSync(path.join(report, 'summary.json'), JSON.stringify({
      passed: process.env.SMOKE_EXIT_CODE === '0', phase: process.env.SMOKE_PHASE,
      release: process.env.SMOKE_RELEASE, loopback_only: true,
      downloads_or_builds: false, systemd_or_docker_mutations: false,
      child_process_cleanup_verified: process.env.SMOKE_CLEANUP_OK === '1',
      elapsed_seconds: Number(process.env.SMOKE_ELAPSED), checks,
    }, null, 2) + '\n')
  } else if (command === 'diagnose') {
    for (const label of ['unicode-core', 'agent']) {
      const filename = path.join(root, 'logs', `${label}.log`)
      if (!fs.existsSync(filename)) continue
      const log = fs.readFileSync(filename, 'utf8')
      console.error(`${label}: log_bytes=${Buffer.byteLength(log)}, bind_error=${/EADDRINUSE|address already in use/i.test(log)}, permission_error=${/EACCES|EPERM|permission denied/i.test(log)}, config_error=${/yaml|configuration.*invalid|Profile YAML/i.test(log)}`)
    }
  } else { throw new SmokeFailure('Unknown smoke helper operation') }
} catch (error) {
  const knownCodes = new Set(['EADDRINUSE', 'EACCES', 'EPERM', 'ECONNREFUSED', 'ETIMEDOUT'])
  console.error(error instanceof SmokeFailure ? error.message :
    knownCodes.has(error?.code) ? `Loopback operation failed (${error.code})` : 'Smoke operation failed; private diagnostics retained')
  process.exitCode = 1
}
EOF_HELPER

pass() { printf 'PASS\t%s\n' "$1" >> "$REPORT/checks.tsv"; printf 'PASS %s\n' "$1"; }
group_exists() { ps -eo pgid= | awk -v group="$1" '$1 == group { found=1 } END { exit !found }'; }
start_group() {
    local label="$1" launcher_variable="$2" group_variable="$3"
    shift 3
    # Expand the positional parameters in the new session, not this shell.
    # shellcheck disable=SC2016
    setsid --wait /bin/bash -c 'printf "%s\n" "$BASHPID" > "$1" || exit 1; shift; exec "$@"' \
        _ "$work/$label.pgid" "$@" > "$work/logs/$label.log" 2>&1 &
    local launcher=$! group="" attempt
    printf -v "$launcher_variable" '%s' "$launcher"
    for (( attempt=0; attempt < 50; attempt++ )); do
        [ ! -s "$work/$label.pgid" ] || { IFS= read -r group < "$work/$label.pgid"; break; }
        kill -0 "$launcher" 2>/dev/null || break
        sleep 0.05
    done
    if [[ ! "$group" =~ ^[0-9]+$ ]] || (( group <= 1 )); then
        kill -TERM "$launcher" 2>/dev/null || :
        wait "$launcher" 2>/dev/null || :
        fail "Could not establish isolated $label process group"
    fi
    [ "$group" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] || fail 'Unsafe process group identity'
    printf -v "$group_variable" '%s' "$group"
}
stop_group() {
    local group="$1" launcher="$2" attempt
    [ -n "$group" ] || return 0
    kill -TERM -- "-$group" 2>/dev/null || :
    for (( attempt=0; attempt < 50; attempt++ )); do
        group_exists "$group" || break
        sleep 0.1
    done
    if group_exists "$group"; then kill -KILL -- "-$group" 2>/dev/null || :; fi
    if [ -n "$launcher" ]; then wait "$launcher" 2>/dev/null || :; fi
    for (( attempt=0; attempt < 20; attempt++ )); do
        group_exists "$group" || return 0
        sleep 0.1
    done
    printf 'Smoke process group did not fully reap: %s\n' "$group" >&2
    return 1
}
finish() {
    local rc=$? cleanup_ok=1
    trap - EXIT INT TERM
    if [ -n "$agent_group" ]; then
        "$NODE" "$work/check.mjs" stop-agent > "$work/logs/stop-agent.log" 2>&1 || :
        stop_group "$agent_group" "$agent_launcher" || cleanup_ok=0
    fi
    if [ -n "$core_group" ]; then stop_group "$core_group" "$core_launcher" || cleanup_ok=0; fi
    if (( cleanup_ok == 0 )); then rc=1; fi
    export SMOKE_EXIT_CODE="$rc" SMOKE_PHASE="$phase" SMOKE_CLEANUP_OK="$cleanup_ok"
    export SMOKE_ELAPSED="$((SECONDS - started_seconds))"
    "$NODE" "$work/check.mjs" summary || rc=1
    if (( rc == 0 )); then
        rm -rf -- "$work"
        printf 'Native smoke report: %s/summary.json\n' "$REPORT"
    else
        printf 'Native smoke stopped during %s; private fixture/logs: %s\n' "$phase" "$work" >&2
        "$NODE" "$work/check.mjs" diagnose >&2 || :
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read -r AGENT_WEB_PORT AGENT_CORE_PORT AGENT_MIXED_PORT UNICODE_CORE_PORT UNICODE_MIXED_PORT < <("$NODE" "$work/check.mjs" ports)
export AGENT_WEB_PORT AGENT_CORE_PORT AGENT_MIXED_PORT
"$NODE" "$work/check.mjs" prepare
sha256sum "$INPUT/"*.yaml "$TEST_DATA/profiles/"* "$TEST_ROOT/deploy/.env" "$TEST_ROOT/deploy/.secrets" > "$work/source-hashes"
cp -- "$TEST_DATA/active.yaml" "$work/active-before-preflight.yaml"
export MIHOMO_REAL_BIN="$RELEASE/mihomo" MIHOMO_NODE_BIN="$NODE"
export MIHOMO_PROXY_BIND_IP=127.0.0.1 MIHOMO_CORE_API_BIND_IP=127.0.0.1
export MIHOMO_KERNEL_TMPDIR="$TEST_MODULE/runtime/host/preflight-tmp"
export MIHOMO_CORE_API_PORT="$AGENT_CORE_PORT" MIHOMO_MIXED_PORT="$AGENT_MIXED_PORT"
phase=ascii-preflight
bash "$RELEASE/launch/host-kernel.sh" -t -d "$TEST_DATA" -f "$TEST_DATA/active.yaml" > "$work/logs/preflight-ascii.log" 2>&1
cmp -s "$TEST_DATA/active.yaml" "$work/active-before-preflight.yaml" || fail 'Native preflight changed shared active.yaml'
pass 'real native preflight accepts old Docker managed header and YAML document marker without rewriting source'

phase=unicode-core
export CLASH_SECRET="$SMOKE_UNICODE_SECRET"
export MIHOMO_CORE_API_PORT="$UNICODE_CORE_PORT" MIHOMO_MIXED_PORT="$UNICODE_MIXED_PORT"
UNICODE_DATA="$TEST_MODULE/runtime/host/unicode-data"
mkdir -p "$UNICODE_DATA"
bash "$RELEASE/launch/host-kernel.sh" -t -d "$UNICODE_DATA" -f "$INPUT/docker-active-unicode.yaml" > "$work/logs/preflight-unicode.log" 2>&1
start_group unicode-core core_launcher core_group /bin/bash "$RELEASE/launch/host-kernel.sh" \
    -d "$UNICODE_DATA" -f "$INPUT/docker-active-unicode.yaml"
ready=0 deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    if "$NODE" "$work/check.mjs" probe > "$work/logs/core-probe.log" 2>&1; then ready=1; break; fi
    kill -0 "$core_launcher" 2>/dev/null || break
    sleep 0.25
done
(( ready == 1 )) || fail 'Unicode fixture Core did not become ready on loopback'
"$NODE" "$work/check.mjs" verify
pass 'real Core accepts UTF-8 API secret bytes and retains node/group/rules and proxy authentication'
stop_group "$core_group" "$core_launcher" || fail 'Unicode Core process cleanup failed'
core_group="" core_launcher=""
"$NODE" "$work/check.mjs" ports-closed "$UNICODE_CORE_PORT" "$UNICODE_MIXED_PORT"
pass 'standalone Core and wrapper are reaped and loopback ports are closed'

phase=agent-web
export CLASH_SECRET="$SMOKE_ASCII_SECRET"
export MIHOMO_CORE_API_PORT="$AGENT_CORE_PORT" MIHOMO_MIXED_PORT="$AGENT_MIXED_PORT"
start_group agent agent_launcher agent_group env -u GITHUB_TOKEN -u DEFAULT_BACKEND_URL \
    /bin/bash "$RELEASE/launch/host-run.sh" "$TEST_MODULE"
ready=0 deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
    if "$NODE" "$RELEASE/launch/host-health.mjs" "http://127.0.0.1:$AGENT_WEB_PORT" \
        "http://127.0.0.1:$AGENT_CORE_PORT" > "$work/logs/health.log" 2>&1; then ready=1; break; fi
    kill -0 "$agent_launcher" 2>/dev/null || break
    sleep 0.5
done
(( ready == 1 )) || fail 'Real Agent/Web/Core did not pass the full release health gate'
# Exercise the supervisor beyond its initial readiness window, rather than
# accepting an API that only briefly opens before the Agent kills its child.
sleep 12
"$NODE" "$RELEASE/launch/host-health.mjs" "http://127.0.0.1:$AGENT_WEB_PORT" \
    "http://127.0.0.1:$AGENT_CORE_PORT" > "$work/logs/health-stable.log" 2>&1
pass 'real Agent stays running; Web HTML/JS/dynamic config and core health pass the production gate'
"$NODE" "$work/check.mjs" verify
pass 'supervised real Core preserves named node/group/rules and returns 407 without proxy credentials'
# The upstream Agent legitimately rewrites active.yaml. Immutable profile
# sources and shared input files, rather than that generated file, are checked.
sha256sum --check "$work/source-hashes" > "$work/logs/source-check.log" 2>&1 || fail 'A profile source or fixture credential/config file was modified'
pass 'original profiles, source YAML and configured fixture values are byte-for-byte unchanged'

phase=cleanup
"$NODE" "$work/check.mjs" stop-agent > "$work/logs/stop-agent.log" 2>&1
stop_group "$agent_group" "$agent_launcher" || fail 'Agent process group cleanup failed'
agent_group="" agent_launcher=""
"$NODE" "$work/check.mjs" ports-closed "$AGENT_WEB_PORT" "$AGENT_CORE_PORT" "$AGENT_MIXED_PORT"
pass 'Agent, core and wrapper children are reaped; all test listeners are closed'
phase=complete
