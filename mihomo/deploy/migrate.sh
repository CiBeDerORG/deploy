#!/usr/bin/env bash
# Creates official Agent data only once, using a staged directory + atomic rename.
# Old static-panel files and already-managed Agent profiles are never deleted.
# Expects common.sh to have been sourced by the caller.

# Preserve the entire old top-level YAML authentication stanza verbatim.
authentication_stanza() {
    awk '
        /^authentication[[:space:]]*:/ { in_auth=1; print; next }
        in_auth && /^[[:alnum:]_-]+[[:space:]]*:/ { exit }
        in_auth { print }
    ' "$1"
}
# Only obsolete static-panel settings are omitted from the copied legacy profile.
legacy_profile_copy() {
    sed '/^external-ui[[:space:]]*:/d; /^external-ui-url[[:space:]]*:/d' "$1" > "$2"
}
initialize_aio() {
    local data="$1" template="$2" web_port="$3"
    local final="$data/all-in-one" old="$data/config.yaml" staging backup auth
    mkdir -p "$data"
    chmod 0700 "$data"
    if [ -d "$final" ] && [ -f "$final/profiles/index.json" ] && [ -f "$final/active.yaml" ]; then
        echo "检测到完整版 Profiles，保持所有已有配置和凭据不变。"
        return 0
    fi
    # An interrupted install must never overwrite the partially written source.
    if [ -e "$final" ]; then
        if [ -d "$final" ] && [ -z "$(ls -A "$final")" ]; then
            rmdir "$final"
        else
            die "完整版数据目录不完整：$final。拒绝覆盖，请先检查备份。"
        fi
    fi
    staging="$(mktemp -d "$data/.aio-stage.XXXXXXXX")" || die "无法创建暂存目录"
    chmod 0700 "$staging"
    mkdir -m 0700 "$staging/profiles"

    if [ -f "$old" ]; then
        backup="$data/backup/pre-all-in-one"
        mkdir -p "$backup"; chmod 0700 "$backup"
        # Never overwrite an older backup, even on repeated attempts.
        if [ ! -e "$backup/config.yaml" ]; then
            cp -p "$old" "$backup/config.yaml"
            chmod 0600 "$backup/config.yaml"
        fi
        legacy_profile_copy "$old" "$staging/profiles/deploy-initial.yaml"
        echo "旧 config.yaml 已保留；新 Profile 来自只移除静态 UI 指令的副本。"
    else
        # A missing legacy config is a clean install. Only then use the optional
        # proxy password in .secrets (never constrain its charset or length).
        secret_when_blank MIHOMO_PROXY_PASSWORD
        cp "$template" "$staging/profiles/deploy-initial.yaml"
        auth="$(yaml_scalar "$MIHOMO_PROXY_USER:$MIHOMO_PROXY_PASSWORD")"
        printf '\nauthentication:\n  - %s\n' "$auth" >> "$staging/profiles/deploy-initial.yaml"
        echo "已创建全新初始 Profile。"
    fi

    cors_yaml "$web_port" > "$staging/profiles/deploy-web-cors.yaml"
    authentication_stanza "$staging/profiles/deploy-initial.yaml" > "$staging/profiles/deploy-proxy-auth.yaml"
    if [ ! -s "$staging/profiles/deploy-proxy-auth.yaml" ]; then
        rm -f "$staging/profiles/deploy-proxy-auth.yaml"
    fi

    # Boot uses active.yaml before the Agent composes any profile. Keep browser
    # compatibility there too, unless the legacy source already has a CORS block.
    cp "$staging/profiles/deploy-initial.yaml" "$staging/active.yaml"
    if ! grep -q '^external-controller-cors[[:space:]]*:' "$staging/active.yaml"; then
        printf '\n' >> "$staging/active.yaml"
        cat "$staging/profiles/deploy-web-cors.yaml" >> "$staging/active.yaml"
    else
        echo "提示：旧配置内已有 CORS，请确认其允许新的 Web 地址；激活 Profile 后会合并新 CORS overlay。"
    fi

    # Official ProfileStore records: keep both overlays enabled for remote URLs,
    # so selecting a subscription cannot silently remove old proxy authentication.
    cat > "$staging/profiles/index.json" <<'EOF_META'
[
  {"id":"deploy-initial","name":"Deploy initial profile","type":"local","updatedAt":0},
  {"id":"deploy-web-cors","name":"Deploy trusted Web origins","type":"merge","enabled":true,"updatedAt":0}
EOF_META
    if [ -f "$staging/profiles/deploy-proxy-auth.yaml" ]; then
        deploy_sed_in_place '$s/}$/},/' "$staging/profiles/index.json"
        printf '  {"id":"deploy-proxy-auth","name":"Deploy proxy authentication","type":"merge","enabled":true,"updatedAt":0}\n' >> "$staging/profiles/index.json"
    fi
    printf ']\n' >> "$staging/profiles/index.json"
    printf '{"activeId":"deploy-initial"}\n' > "$staging/profiles/state.json"
    chmod 0600 "$staging/active.yaml" "$staging/profiles/"*
    mv "$staging" "$final" || die "初始化持久化目录失败"
    echo "完整版数据已初始化：$final（旧数据保留）"
}
