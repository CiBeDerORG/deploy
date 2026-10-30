#!/usr/bin/env bash
# OpenHands-only configuration parser; never source .env or .secrets as shell.
fail() { printf 'OpenHands 部署错误：%s\n' "$*" >&2; exit 1; }
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo -- bash "$0" "$@"; fi
    fail "请使用 root 或 sudo 执行"
  fi
}
check_docker() {
  command -v docker >/dev/null 2>&1 || fail "缺少 Docker"
  docker compose version >/dev/null 2>&1 || fail "缺少 Docker Compose v2"
  docker info >/dev/null 2>&1 || fail "Docker 未启动"
}
declare -gA SEEN=()
load_file() {
  local file="$1" kind="$2" line key value trimmed number=0
  [ -f "$file" ] || fail "缺少配置文件 $file；请先执行 deploy.sh env"
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue;; esac
    [[ "$line" == *=* ]] || fail "$file:$number 不是 KEY=VALUE"
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "$file:$number 变量名非法"
    case "$key" in
      OPENHANDS_IMAGE|OPENHANDS_BIND_IP|OPENHANDS_PORT|TZ)
        [ "$kind" = env ] || fail "$key 应放在 deploy/.env";;
      OPENHANDS_API_KEY)
        [ "$kind" = secrets ] || fail "$key 必须放在 deploy/.secrets";;
      *) continue;;
    esac
    [[ ! ${SEEN[$key]+set} ]] || fail "$key 被重复定义"
    SEEN[$key]=1
    value="${line#*=}"
    trimmed="${value#"${value%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -z "$trimmed" ]; then
      value=''
    elif [[ "$trimmed" == \"* ]] || [[ "$trimmed" == \'* ]]; then
      case "${trimmed:0:1}" in
        '"') [ "${trimmed: -1}" = '"' ] && [ "${#trimmed}" -ge 2 ] || fail "$file:$number 双引号未闭合";;
        "'") [ "${trimmed: -1}" = "'" ] && [ "${#trimmed}" -ge 2 ] || fail "$file:$number 单引号未闭合";;
      esac
      value="${trimmed:1:${#trimmed}-2}"
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"
}
load_config() {
  [ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] || fail "请先执行 sudo bash deploy.sh env"
  chown root:root "$ENV_FILE" "$SECRETS_FILE"
  chmod 0600 "$ENV_FILE" "$SECRETS_FILE"
  SEEN=()
  load_file "$ENV_FILE" env
  load_file "$SECRETS_FILE" secrets
}
validate_config() {
  local octet
  local -a parts=()
  [[ "$OPENHANDS_PORT" =~ ^[0-9]+$ ]] && ((10#$OPENHANDS_PORT >= 1 && 10#$OPENHANDS_PORT <= 65535)) ||
    fail "OPENHANDS_PORT 必须是 1-65535 的数字"
  [[ "$OPENHANDS_BIND_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
    fail "OPENHANDS_BIND_IP 必须是合法 IPv4"
  IFS=. read -r -a parts <<< "$OPENHANDS_BIND_IP"
  for octet in "${parts[@]}"; do ((10#$octet <= 255)) || fail "OPENHANDS_BIND_IP 非法"; done
  [ -n "$OPENHANDS_IMAGE" ] && [[ ! "$OPENHANDS_IMAGE" =~ [[:space:]] ]] ||
    fail "OPENHANDS_IMAGE 格式错误"
}
check_container_owner() {
  local project
  if docker container inspect openhands >/dev/null 2>&1; then
    project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' openhands 2>/dev/null || true)"
    [ "$project" = openhands ] || fail "同名容器不属于本 Compose 项目，拒绝覆盖"
  elif [ "$MODE" = update ]; then
    fail "未安装 OpenHands，请先执行 install"
  fi
}
persist_generated_api_key() {
  local temp
  temp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXXXX")" || fail "无法创建密钥暂存文件"
  # Only remove the previously validated blank key, never another secret.
  if ! awk '$0 !~ /^[[:space:]]*OPENHANDS_API_KEY[[:space:]]*=/' "$SECRETS_FILE" > "$temp" ||
     ! printf '\nOPENHANDS_API_KEY=%s\n' "$OPENHANDS_API_KEY" >> "$temp" ||
     ! chown root:root "$temp" || ! chmod 0600 "$temp" ||
     ! mv -f -- "$temp" "$SECRETS_FILE"; then
    rm -f -- "$temp"
    fail "密钥保存失败"
  fi
}
