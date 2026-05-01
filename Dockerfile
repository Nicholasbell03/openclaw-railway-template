FROM node:22-slim

RUN apt-get update && apt-get install -y \
      git curl procps python3 make g++ cron tini \
      chromium fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG WIREPROXY_VERSION=1.1.2
RUN curl -fsSL -o /tmp/wireproxy.tar.gz \
      "https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}/wireproxy_linux_${TARGETARCH:-amd64}.tar.gz" \
    && tar -xzf /tmp/wireproxy.tar.gz -C /tmp/ wireproxy \
    && mv /tmp/wireproxy /usr/local/bin/wireproxy \
    && chmod +x /usr/local/bin/wireproxy \
    && rm /tmp/wireproxy.tar.gz

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --prefer-online && npm cache clean --force

RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data
ENV OPENCLAW_BROWSER_HEADLESS=1

RUN mkdir -p /data

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/entrypoint.sh"]
