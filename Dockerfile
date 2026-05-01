FROM node:22-slim

RUN apt-get update && apt-get install -y \
      git curl procps python3 make g++ cron tini \
      chromium fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --prefer-online && npm cache clean --force

RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data
ENV OPENCLAW_BROWSER_HEADLESS=1

RUN mkdir -p /data

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["alphaclaw", "start"]
