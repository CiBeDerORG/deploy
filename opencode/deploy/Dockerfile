FROM mcr.microsoft.com/devcontainers/typescript-node:24

USER root

# OpenCode V2 使用官方安装器，固定安装 latest。
# 代理仅在 Docker build 当前 RUN 中导出，不写入最终运行环境。
ARG OPENCODE_CACHE_BUST=manual
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

RUN set -eux; \
    echo "OpenCode V2 cache bust: ${OPENCODE_CACHE_BUST}"; \
    export http_proxy="${HTTP_PROXY:-}"; \
    export https_proxy="${HTTPS_PROXY:-}"; \
    export no_proxy="${NO_PROXY:-}"; \
    if [ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]; then \
        echo "Build proxy: enabled"; \
    else \
        echo "Build proxy: disabled"; \
    fi; \
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path; \
    test -x /root/.opencode/bin/opencode; \
    ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode; \
    if [ -x /root/.opencode/bin/opencode2 ]; then \
        ln -sf /root/.opencode/bin/opencode2 /usr/local/bin/opencode2; \
    else \
        ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode2; \
    fi; \
    command -v opencode; \
    opencode --version

COPY docker-entrypoint.sh /usr/local/bin/opencode-entrypoint
RUN chmod 0755 /usr/local/bin/opencode-entrypoint

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/opencode-entrypoint"]
