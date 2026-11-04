#!/usr/bin/env bash
# 只把上一代官方默认值迁移为当前已发布的默认值；自定义来源绝不改动。
# 由 root 安装器 source 并在解析 .env 前调用，不执行 .env 内容。
deploy_migrate_published_default() {
    local file="$1" key="$2" old="$3" latest="$4" tmp
    if [[ ! -f "$file" || -L "$file" || "$(stat -c '%u:%g:%a' "$file")" != 0:0:600 ]]; then
        printf '无法安全迁移 %s：.env 需要是 root:root 0600 普通文件\n' "$key" >&2
        return 1
    fi
    tmp="$(mktemp "$file.source-migrate.XXXXXXXX")" || return 1
    # AWK 只处理目标键，不解释 Shell，保留其他原始行/注释/密码配置。
    if ! awk -v wanted="$key" -v former="$old" -v latest="$latest" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        {
            line=$0
            match_line=line
            sub(/\r$/, "", match_line)
            sep=index(match_line,"=")
            if (sep > 0) {
                k=trim(substr(match_line,1,sep-1))
                if (k == wanted) {
                    count++
                    value=trim(substr(match_line,sep+1))
                    quote=substr(value,1,1)
                    if (length(value)>=2 && (quote==sprintf("%c",34) || quote==sprintf("%c",39)) &&
                        substr(value,length(value),1)==quote) {
                        value=substr(value,2,length(value)-2)
                    }
                    if (value == former) {
                        print wanted "=" latest
                        changed=1
                        next
                    }
                }
            }
            print line
        }
        END { if (count>1) exit 3 }
    ' "$file" > "$tmp"; then
        rm -f -- "$tmp"
        printf '无法安全迁移 %s：配置可能存在重复键\n' "$key" >&2
        return 1
    fi
    if cmp -s -- "$file" "$tmp"; then
        rm -f -- "$tmp"
        return 0
    fi
    if ! chown root:root -- "$tmp" || ! chmod 0600 -- "$tmp" || ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        printf '写回 %s 的新默认来源失败\n' "$key" >&2
        return 1
    fi
    printf '已将 %s 的旧默认来源迁移到当前开发分支发布版本\n' "$key"
}
