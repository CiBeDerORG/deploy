// Never modify the source YAML or print parser excerpts containing credentials.
import { readFile, realpath, writeFile } from 'node:fs/promises'
import { isIP } from 'node:net'
import { resolve } from 'node:path'
import { Document, isMap, isScalar, parseAllDocuments, visit } from 'yaml'

class ConfigFailure extends Error {}
const fail = (message) => { throw new ConfigFailure(message) }
function port(name, fallback) {
  const raw = process.env[name] || String(fallback)
  if (!/^\d{1,5}$/.test(raw)) fail(`${name} 必须是端口数字`)
  const value = Number.parseInt(raw, 10)
  if (value < 1 || value > 65535) fail(`${name} 超出 TCP 端口范围`)
  return value
}
function ipv4(name, fallback) {
  const value = process.env[name] || fallback
  if (isIP(value) !== 4) fail(`${name} 必须是 IPv4 地址`)
  return value
}

try {
  const [input, output, ...extra] = process.argv.slice(2)
  if (!input || !output || extra.length) fail('Usage: host-config.mjs INPUT OUTPUT')
  if (await realpath(input) === resolve(output)) fail('拒绝覆盖原始 Profile')
  const mixed = port('MIHOMO_MIXED_PORT', 7011)
  const core = port('MIHOMO_CORE_API_PORT', 7013)
  const proxyIP = ipv4('MIHOMO_PROXY_BIND_IP', '127.0.0.1')
  const coreIP = ipv4('MIHOMO_CORE_API_BIND_IP', '0.0.0.0')
  let source = await readFile(input, 'utf8')
  const hasSecret = Object.hasOwn(process.env, 'CLASH_SECRET')
  const secret = process.env.CLASH_SECRET

  // MetaCubeXD v1.273.1 injectClashConfig prepends these exact three lines,
  // including an unquoted secret and only ONE final newline. Ports may still
  // be Docker/previous-install ports during preflight; the raw secret must
  // match our environment before we remove this recognized management header.
  // Do not discard arbitrary user-authored YAML documents.
  if (hasSecret) {
    const controller = /^external-controller: 0\.0\.0\.0:([0-9]{1,5})\n/.exec(source)
    if (controller && Number(controller[1]) >= 1 && Number(controller[1]) <= 65535) {
      const prefix = controller[0] + `secret: ${secret}\n`
      if (source.startsWith(prefix)) {
        const listener = /^mixed-port: ([0-9]{1,5})\n/.exec(source.slice(prefix.length))
        if (listener && Number(listener[1]) >= 1 && Number(listener[1]) <= 65535) {
          source = source.slice(prefix.length + listener[0].length)
        }
      }
    }
  }
  // Go decodes numeric-looking scalars into string fields from their original
  // text (e.g. password: 00123). Preserve unmodified scalar tokens, without
  // converting ordinary numeric/boolean fields to strings. These are public
  // yaml APIs: https://eemeli.org/yaml/#custom-data-types
  const originalScalars = new WeakMap()
  const customTags = (tags) => tags.map((tag) => typeof tag.stringify !== 'function' ? tag : {
    ...tag,
    stringify(node, ...args) {
      const original = originalScalars.get(node)
      if (original && Object.is(original.value, node.value)) return original.source
      return tag.stringify(node, ...args)
    },
  })
  const documents = parseAllDocuments(source, {
    uniqueKeys: true, prettyErrors: false, keepSourceTokens: true, customTags,
  })
  if (documents.length > 1) fail('原生 Profile 只支持单个 YAML 文档；拒绝丢弃后续文档')
  const document = documents[0] || new Document({})
  if (document.errors.length) fail('Profile YAML 无效或包含重复键；原文件未修改')
  if (document.contents === null) document.contents = document.createNode({})
  if (!isMap(document.contents)) fail('Profile 顶层必须是 YAML 映射')
  visit(document, { Scalar(_key, node) {
    const token = node.srcToken
    if (typeof node.value !== 'string' && token?.type === 'scalar' && !/[\r\n]/.test(token.source)) {
      originalScalars.set(node, { value: node.value, source: token.source })
    }
  } })
  const setManaged = (key, value) => {
    const old = document.get(key, true)
    const next = document.createNode(value)
    // Fresh scalars discard an old explicit tag, quoted style or OCT format.
    // Preserve anchors/comments so references still resolve to the new value.
    if (isScalar(old)) {
      for (const property of ['anchor', 'comment', 'commentBefore']) {
        if (old[property] !== undefined) next[property] = old[property]
      }
    }
    document.set(key, next)
  }
  setManaged('external-controller', `${coreIP}:${core}`)
  setManaged('mixed-port', mixed)
  setManaged('allow-lan', true)
  setManaged('bind-address', proxyIP === '0.0.0.0' ? '*' : proxyIP)
  if (hasSecret) setManaged('secret', secret)
  // Match the upstream policy: the managed mixed listener owns this port.
  for (const key of ['port', 'socks-port', 'redir-port', 'tproxy-port']) {
    if (document.get(key) === mixed) document.delete(key)
  }
  await writeFile(output, document.toString({ lineWidth: 0 }), { mode: 0o600 })
} catch (error) {
  console.error(error instanceof ConfigFailure ? error.message : '无法安全生成原生 Profile；原文件未修改')
  process.exitCode = 1
}
