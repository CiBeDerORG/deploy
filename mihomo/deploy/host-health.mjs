// Verify the actual Web assets and dynamic control-token route, not only API
// health. Credentials and authenticated request URLs are never printed.
import { get as httpGet, validateHeaderValue } from 'node:http'
import { get as httpsGet } from 'node:https'

class CheckFailure extends Error {}
const check = (ok, message) => { if (!ok) throw new CheckFailure(message) }
async function get(url, headers) {
  check(url.protocol === 'http:' || url.protocol === 'https:', 'HTTP 验收地址协议无效')
  return await new Promise((resolve, reject) => {
    const request = (url.protocol === 'https:' ? httpsGet : httpGet)(url, {
      headers, signal: AbortSignal.timeout(4000),
    }, (response) => {
      const chunks = []
      response.on('data', (chunk) => chunks.push(chunk))
      response.on('error', reject)
      response.on('end', () => {
        if (!(response.statusCode >= 200 && response.statusCode < 300)) {
          reject(new CheckFailure('HTTP 验收端点未返回成功状态'))
          return
        }
        const text = Buffer.concat(chunks).toString('utf8')
        resolve({
          headers: new Map(Object.entries(response.headers)),
          text: async () => text,
          json: async () => JSON.parse(text),
        })
      })
    })
    request.on('error', reject)
  })
}
function coreAuthorization(secret) {
  // Node's http client writes header strings as latin1. Encode the original
  // UTF-8 bytes explicitly so Go receives the exact configured secret, unlike
  // fetch's WebIDL ByteString conversion. HTTP forbids CR/LF and other control
  // bytes: https://nodejs.org/api/http.html#httpvalidateheadervaluename-value
  const encoded = Buffer.from(`Bearer ${secret}`, 'utf8').toString('latin1')
  try { validateHeaderValue('Authorization', encoded) }
  catch { throw new CheckFailure('内核 API 密钥含有 HTTP 请求头不允许的控制字符，无法无损发送验收认证') }
  return encoded
}
async function json(response, label) {
  try { return await response.json() } catch { throw new CheckFailure(`${label} 未返回 JSON`) }
}
try {
  const [webArg, coreArg, ...extra] = process.argv.slice(2)
  check(webArg && coreArg && (extra.length === 0 || (extra.length === 1 && extra[0] === '--service-only')),
    'Usage: host-health.mjs WEB_URL CORE_URL [--service-only]')
  const serviceOnly = extra[0] === '--service-only'
  const web = new URL(webArg)
  const core = new URL(coreArg)
  const token = process.env.CONTROL_TOKEN
  const secret = process.env.CLASH_SECRET
  check(typeof token === 'string' && token.length > 0 && typeof secret === 'string', '缺少验收认证环境')
  const [healthResponse, coreResponse] = await Promise.all([
    // Official Agent health is public; no credential needs this transport.
    get(new URL('/api/control/health', web)),
    get(new URL('/version', core), { Authorization: coreAuthorization(secret) }),
  ])
  await json(healthResponse, 'Agent 健康接口')
  const version = await json(coreResponse, '内核版本接口')
  check(typeof version?.version === 'string' && version.version.length > 0, '内核版本接口响应异常')
  if (serviceOnly) {
    console.log('Legacy Agent/core service health passed')
    process.exit(0)
  }
  // /health is only liveness. Require the Agent's own supervisor to consider
  // the core running, otherwise it may still terminate it after our /version
  // probe succeeds. The official query-token transport preserves Unicode.
  const statusURL = new URL('/api/control/kernel/status', web)
  statusURL.searchParams.set('token', token)
  const [home, configResponse, statusResponse] = await Promise.all([
    get(new URL('/', web)),
    get(new URL('/config.js', web)),
    get(statusURL),
  ])
  const status = await json(statusResponse, 'Agent 内核状态接口')
  check(status?.status === 'running', 'Agent 尚未确认内核就绪，请检查模块内 service-error.log 与 service.log')
  check(/text\/html/i.test(home.headers.get('content-type') || ''), 'Web 首页类型异常')
  const html = await home.text()
  const scripts = [...html.matchAll(/<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>/gi)]
    .map((match) => new URL(match[1], web))
  const script = scripts.find((url) => url.origin === web.origin && url.pathname !== '/config.js' && /\.m?js$/.test(url.pathname))
  check(script, 'Web 首页缺少应用 JavaScript 资源')
  const asset = await get(script)
  check(/(?:java|ecma)script/i.test(asset.headers.get('content-type') || ''), '应用 JavaScript 资源类型异常')
  const js = await asset.text()
  check(js.trim().length > 0 && !/^\s*(?:<!doctype|<html)/i.test(js), '应用 JavaScript 资源错误地返回 HTML')
  check(/(?:java|ecma)script/i.test(configResponse.headers.get('content-type') || ''), '动态 config.js 类型异常')
  check(/no-store/i.test(configResponse.headers.get('cache-control') || ''), 'config.js 未使用动态无缓存路由')
  const configText = await configResponse.text()
  const prefix = 'window.__METACUBEXD_CONFIG__ = '
  check(configText.startsWith(prefix), '动态 config.js 内容异常')
  let config
  try { config = JSON.parse(configText.slice(prefix.length).trim().replace(/;$/, '')) }
  catch { throw new CheckFailure('动态 config.js 未返回可验证配置') }
  check(config.controlToken === token, 'config.js 未注入当前 Agent 凭据')
  console.log('Native Web HTML/JS/dynamic config and core health passed')
} catch (error) {
  console.error(error instanceof CheckFailure ? error.message : '原生 Web/内核验收请求失败')
  process.exitCode = 1
}
