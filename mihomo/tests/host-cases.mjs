import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { createServer } from 'node:http'
import { chmod, copyFile, mkdir, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parse, stringify } from 'yaml'

const exec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const source = resolve(process.argv[2])
const work = dirname(here)
const tmp = join(work, 'kernel-tmp')
const input = join(work, 'active.yaml')
const realCore = join(work, 'fixture-core.sh')
await writeFile(realCore, '#!/bin/bash\nset -eu\nwhile [ "$#" -gt 0 ]; do\nif [ "$1" = -v ]; then echo fixture-version; exit 0; fi\nif [ "$1" = -f ]; then cat "$2"; exit 0; fi\nshift\ndone\nexit 2\n')
await chmod(realCore, 0o755)
const secrets = [
  'space colon: value # marker',
  '单双引号\'" dollar$ ! [] {} \\ trailing ',
  '#leading-hash',
  'true',
  '012345',
]
const profile = {
  'external-controller': '0.0.0.0:9090',
  'mixed-port': 7890,
  'allow-lan': false,
  'bind-address': '*',
  authentication: ['用户 空格:保留原值# : \'" $![]'],
  proxies: [{ name: '节点一', type: 'socks5', server: 'example.invalid', port: 1080, username: '用户', password: 'p # : \'"' }],
  'proxy-groups': [{ name: '手动', type: 'select', proxies: ['节点一'] }],
  rules: ['MATCH,手动'],
  'external-controller-cors': { 'allow-origins': ['http://127.0.0.1:7012'] },
}
const plain = '---\n' + stringify(profile).replace('external-controller:', '"external-controller":').replace('mixed-port:', 'mixed-port :')
const env = {
  ...process.env,
  MIHOMO_REAL_BIN: realCore,
  MIHOMO_NODE_BIN: process.execPath,
  MIHOMO_KERNEL_TMPDIR: tmp,
  MIHOMO_PROXY_BIND_IP: '127.0.0.1',
  MIHOMO_CORE_API_BIND_IP: '0.0.0.0',
  MIHOMO_MIXED_PORT: '07011',
  MIHOMO_CORE_API_PORT: '07013',
  CLASH_API_PORT: '7013',
  MIXED_PORT: '7011',
}
let lastConfig = ''
async function convert(text, overrides = {}) {
  await writeFile(input, text)
  const original = await readFile(input)
  const result = await exec('/bin/bash', [join(here, 'launch/host-kernel.sh'), '-t', '-d', work, '-f', input], { env: { ...env, ...overrides } })
  assert.deepEqual(await readFile(input), original, 'original Profile changed')
  assert.equal((await readdir(tmp)).length, 0, 'runtime config leaked after core exit')
  lastConfig = result.stdout
  return parse(result.stdout)
}
function preserved(actual) {
  for (const key of ['authentication', 'proxies', 'proxy-groups', 'rules', 'external-controller-cors']) {
    assert.deepEqual(actual[key], profile[key], `profile field was lost: ${key}`)
  }
  assert.equal(actual['mixed-port'], 7011)
  assert.equal(actual['external-controller'], '0.0.0.0:7013')
  assert.equal(actual['bind-address'], '127.0.0.1')
}
for (const secret of secrets) {
  const unmodified = await convert(plain, { CLASH_SECRET: secret })
  preserved(unmodified)
  assert.equal(unmodified.secret, secret)
  for (const [oldCore, oldMixed] of [[7013, 7011], [9090, 7890]]) {
    const header = `external-controller: 0.0.0.0:${oldCore}\nsecret: ${secret}\nmixed-port: ${oldMixed}\n`
    const injected = await convert(header + plain, { CLASH_SECRET: secret })
    preserved(injected)
    assert.equal(injected.secret, secret)
  }
}
const wildcard = await convert(plain, { CLASH_SECRET: secrets[0], MIHOMO_PROXY_BIND_IP: '0.0.0.0', MIHOMO_CORE_API_BIND_IP: '127.0.0.1' })
assert.equal(wildcard['bind-address'], '*')
assert.equal(wildcard['external-controller'], '127.0.0.1:7013')
await convert('proxies:\n  - name: numeric-credential\n    type: socks5\n    server: example.invalid\n    port: 1080\n    username: 1e03\n    password: 00123\nkeep-alive-interval: 030\n', { CLASH_SECRET: secrets[0] })
for (const scalar of ['port: 1080', 'username: 1e03', 'password: 00123', 'keep-alive-interval: 030']) {
  assert.ok(lastConfig.includes(scalar), 'unmanaged numeric scalar spelling/type changed')
}
const typed = await convert('%YAML 1.1\n---\nmixed-port: 07011\nsecret: !!int 123\n', { CLASH_SECRET: secrets[0] })
assert.equal(typed['mixed-port'], 7011)
assert.equal(typed.secret, secrets[0])
assert.match(lastConfig, /mixed-port: 7011\n/)
for (const invalid of [
  'authentication: [keep]\n---\nrules: [MATCH,DIRECT]\n',
  'mixed-port: 7890\n"mixed-port": 7891\n',
  'proxies: [broken\n',
  'external-controller: 0.0.0.0:7013\nsecret: another\nmixed-port: 7011\n\n' + plain,
]) {
  await writeFile(input, invalid)
  await assert.rejects(() => exec('/bin/bash', [join(here, 'launch/host-kernel.sh'), '-t', '-f', input], { env: { ...env, CLASH_SECRET: secrets[0] } }), (error) => {
    assert.ok(error.code !== 0)
    for (const secret of secrets) assert.ok(!error.stderr.includes(secret), 'secret exposed in validation error')
    return true
  })
  assert.equal(await readFile(input, 'utf8'), invalid)
  assert.equal((await readdir(tmp)).length, 0)
}
console.log('YAML: document marker, quoted keys, credentials, decimal ports, ambiguity and cleanup passed')

// Supervisor sends signals to the wrapper PID, including direct SIGKILL on a
// startup timeout. The real process must replace it, not become its child.
const longCore = join(work, 'fixture-long-core.sh')
const corePid = join(work, 'core.pid')
await writeFile(longCore, '#!/bin/bash\nprintf "%s" "$$" > "$MIHOMO_TEST_PID_FILE"\nexec sleep 30\n')
await chmod(longCore, 0o755)
await writeFile(input, plain)
const supervised = spawn('/bin/bash', [join(here, 'launch/host-kernel.sh'), '-f', input], {
  env: { ...env, MIHOMO_REAL_BIN: longCore, MIHOMO_TEST_PID_FILE: corePid, CLASH_SECRET: secrets[0] },
  stdio: 'ignore',
})
const exited = new Promise((done, reject) => { supervised.on('exit', done); supervised.on('error', reject) })
try {
  let started = false
  for (let attempt = 0; attempt < 100; attempt++) {
    try { assert.equal(Number(await readFile(corePid, 'utf8')), supervised.pid); started = true; break }
    catch (error) { if (error.code !== 'ENOENT') throw error }
    await new Promise((done) => setTimeout(done, 10))
  }
  assert.ok(started, 'supervised core did not start')
  assert.equal((await readdir(tmp)).length, 0, 'runtime credentials left a pathname while running')
  supervised.kill('SIGKILL')
  await exited
  assert.throws(() => process.kill(supervised.pid, 0), { code: 'ESRCH' })
} finally { supervised.kill('SIGKILL'); await exited }
console.log('Supervisor: exec PID ownership and SIGKILL cleanup passed')

// Pin an actual launcher's dependencies even if current is changed while the
// config loader is running. The fixture Agent verifies paths without logging
// any configured value, and no system service or Docker daemon is used.
const moduleDir = join(work, 'module')
const runtime = join(moduleDir, 'runtime/host')
const a = join(runtime, 'releases/a')
const b = join(runtime, 'releases/b')
await mkdir(join(a, 'launch'), { recursive: true })
await mkdir(join(a, 'server'), { recursive: true })
await mkdir(join(a, 'ui-dist'), { recursive: true })
await mkdir(join(a, 'node_modules/yaml'), { recursive: true })
await mkdir(b, { recursive: true })
await writeFile(join(a, 'ui-dist/index.html'), '<html></html>')
await writeFile(join(a, 'node_modules/yaml/package.json'), '{}')
await copyFile(realCore, join(a, 'mihomo'))
await chmod(join(a, 'mihomo'), 0o755)
await symlink(dirname(dirname(process.execPath)), join(a, 'node'))
await symlink('releases/a', join(runtime, 'current'))
for (const name of ['host-run.sh', 'host-kernel.sh', 'host-config.mjs']) await copyFile(join(source, name), join(a, 'launch', name))
const commonPath = join(a, 'launch/common.sh')
await writeFile(commonPath, `die() { echo fixture-failure >&2; exit 1; }\ncheck_port() { :; }\ncheck_ipv4() { :; }\nload_settings() {\n export MIHOMO_MIXED_PORT=07011 MIHOMO_API_PORT=07012 MIHOMO_CORE_API_PORT=07013\n export MIHOMO_CONTROL_TOKEN=fixture-control MIHOMO_API_SECRET=fixture-secret\n ln -sfn releases/b "$MODULE/runtime/host/current"\n}\n`)
await writeFile(join(a, 'server/index.mjs'), `import assert from 'node:assert/strict';\nimport {realpathSync,writeFileSync} from 'node:fs';\nimport {dirname} from 'node:path';\nconst release=dirname(dirname(new URL(import.meta.url).pathname));\nassert.equal(process.env.UI_DIST,release+'/ui-dist');\nassert.equal(process.env.MIHOMO_REAL_BIN,release+'/mihomo');\nassert.equal(process.env.MIHOMO_BIN,release+'/launch/host-kernel.sh');\nassert.equal(process.env.MIXED_PORT,'7011');\nassert.equal(process.env.CLASH_API_PORT,'7013');\nassert.ok(process.env.TMPDIR.startsWith(process.env.DATA_DIR.replace('/data/all-in-one','')+'/runtime/host/'));\nassert.ok(realpathSync(process.env.DATA_DIR.replace('/data/all-in-one','')+'/runtime/host/current').endsWith('/b'));\nwriteFileSync(release+'/launcher-ok','passed');\n`)
const mocks = join(work, 'mocks')
await mkdir(mocks)
await writeFile(join(mocks, 'docker'), '#!/bin/sh\nexit 1\n')
await chmod(join(mocks, 'docker'), 0o755)
const launcherEnv = { ...process.env, PATH: `${mocks}:${process.env.PATH}` }
await exec('/bin/bash', [join(runtime, 'current/launch/host-run.sh'), moduleDir], { env: launcherEnv })
assert.equal(await readFile(join(a, 'launcher-ok'), 'utf8'), 'passed')
// An old unit's mirror entry must hand off to the versioned release.
await mkdir(join(moduleDir, 'deploy'), { recursive: true })
await copyFile(join(source, 'host-run.sh'), join(moduleDir, 'deploy/host-run.sh'))
await rm(join(runtime, 'current'))
await symlink('releases/a', join(runtime, 'current'))
await rm(join(a, 'launcher-ok'))
await exec('/bin/bash', [join(moduleDir, 'deploy/host-run.sh')], { env: launcherEnv })
assert.equal(await readFile(join(a, 'launcher-ok'), 'utf8'), 'passed')
// A synced mirror must also boot the pre-versioned layout if installation
// fails before the old release can be sealed with its own launch directory.
const legacy = join(runtime, 'releases/legacy')
await mkdir(join(legacy, 'server'), { recursive: true })
await mkdir(join(legacy, 'ui-dist'), { recursive: true })
await copyFile(realCore, join(legacy, 'mihomo'))
await chmod(join(legacy, 'mihomo'), 0o755)
await writeFile(join(legacy, 'ui-dist/index.html'), '<html></html>')
await copyFile(join(source, 'host-legacy-run.sh'), join(moduleDir, 'deploy/host-legacy-run.sh'))
await copyFile(commonPath, join(moduleDir, 'deploy/common.sh'))
await writeFile(join(moduleDir, 'deploy/common.sh'), 'die() { echo fixture-failure >&2; exit 1; }\nload_settings() { export MIHOMO_CONTROL_TOKEN=fixture-control MIHOMO_API_SECRET=fixture-secret; }\n')
await writeFile(join(legacy, 'server/index.mjs'), `import assert from 'node:assert/strict';\nimport {writeFileSync} from 'node:fs';\nimport {dirname} from 'node:path';\nconst release=dirname(dirname(new URL(import.meta.url).pathname));\nassert.equal(process.env.UI_DIST,release+'/ui-dist');\nassert.equal(process.env.MIHOMO_REAL_BIN,release+'/mihomo');\nassert.ok(process.env.MIHOMO_BIN.endsWith('/deploy/host-legacy-run.sh'));\nwriteFileSync(release+'/launcher-ok','passed');\n`)
await symlink(dirname(dirname(process.execPath)), join(runtime, 'node-current'))
await rm(join(runtime, 'current'))
await symlink('releases/legacy', join(runtime, 'current'))
await exec('/bin/bash', [join(moduleDir, 'deploy/host-run.sh')], { env: launcherEnv })
assert.equal(await readFile(join(legacy, 'launcher-ok'), 'utf8'), 'passed')
console.log('Launcher: immutable paths, old-unit bridge and unsealed legacy layout passed')

// Real loopback HTTP requests validate the acceptance helper, including the
// regression where API health succeeds but the static /config.js masks auth.
let mode = 'ok'
const token = 'fixture-control-with-\'"-中文'
const secret = 'fixture-core-secret-单双引号\'" 空格 # :'
const server = createServer((req, res) => {
  const json = (obj) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(obj)) }
  if (req.url === '/api/control/health') {
    assert.equal(req.headers.authorization, undefined, 'public health should not send credentials')
    return json({ status: 'ok' })
  }
  if (req.url === '/version') {
    const received = Buffer.from(req.headers.authorization || '', 'latin1').toString('utf8')
    if (mode === 'core-auth' || received !== `Bearer ${secret}`) { res.statusCode = 401; return res.end() }
    return json({ version: 'fixture' })
  }
  if (req.url.startsWith('/api/control/kernel/status?')) {
    const received = new URL(req.url, 'http://localhost').searchParams.get('token')
    if (received !== token) { res.statusCode = 401; return res.end() }
    return json({ status: mode === 'agent-starting' ? 'starting' : mode === 'agent-errored' ? 'errored' : 'running' })
  }
  if (req.url === '/') { res.setHeader('content-type', 'text/html'); return res.end('<html><script src="/config.js"></script><script type="module" src="/_nuxt/app.js"></script></html>') }
  if (req.url === '/_nuxt/app.js') {
    if (mode === 'missing-js') { res.statusCode = 404; return res.end() }
    res.setHeader('content-type', mode === 'html-js' ? 'text/html' : 'text/javascript')
    return res.end(mode === 'html-js' ? '<html></html>' : 'console.log("fixture")')
  }
  if (req.url === '/config.js') {
    res.setHeader('content-type', 'text/javascript')
    if (mode !== 'static-config') res.setHeader('cache-control', 'no-store')
    return res.end('window.__METACUBEXD_CONFIG__ = ' + JSON.stringify(mode === 'static-config' ? { defaultBackendURL: '' } : { controlToken: token }))
  }
  res.statusCode = 404; res.end()
})
await new Promise((done) => server.listen(0, '127.0.0.1', done))
try {
  const url = `http://127.0.0.1:${server.address().port}`
  for (mode of ['ok', 'missing-js', 'html-js', 'static-config', 'core-auth', 'agent-starting', 'agent-errored']) {
    let result
    try { result = await exec(process.execPath, [join(here, 'launch/host-health.mjs'), url, url], { env: { ...process.env, CONTROL_TOKEN: token, CLASH_SECRET: secret } }) }
    catch (error) { result = error }
    if (mode === 'ok') assert.equal(result.code, undefined)
    else assert.ok(result.code !== undefined && result.code !== 0, `${mode} was accepted`)
    assert.ok(!(result.stdout || '').includes(token) && !(result.stderr || '').includes(token))
    assert.ok(!(result.stdout || '').includes(secret) && !(result.stderr || '').includes(secret))
  }
  mode = 'static-config'
  await exec(process.execPath, [join(here, 'launch/host-health.mjs'), url, url, '--service-only'], { env: { ...process.env, CONTROL_TOKEN: token, CLASH_SECRET: secret } })
  mode = 'core-auth'
  await assert.rejects(() => exec(process.execPath, [join(here, 'launch/host-health.mjs'), url, url, '--service-only'], { env: { ...process.env, CONTROL_TOKEN: token, CLASH_SECRET: secret } }))
  mode = 'ok'
  await assert.rejects(() => exec(process.execPath, [join(here, 'launch/host-health.mjs'), url, url], { env: { ...process.env, CONTROL_TOKEN: token, CLASH_SECRET: 'invalid\r\ncredential' } }), (error) => {
    assert.ok(!error.stderr.includes('invalid\r\ncredential'))
    return true
  })
} finally { await new Promise((done) => server.close(done)) }
console.log('HTTP acceptance: HTML/JS/dynamic config/core and failure detection passed')
