FROM node:22-alpine AS base

FROM base AS deps

RUN apk add --no-cache libc6-compat python3 make g++ build-base cairo-dev jpeg-dev pango-dev giflib-dev

WORKDIR /app

COPY package.json yarn.lock ./

# Use build arg to allow registry customization
# Default to official registry, can override with --build-arg YARN_REGISTRY=https://registry.npmmirror.com/
ARG YARN_REGISTRY=https://registry.yarnpkg.com
RUN yarn config set registry "${YARN_REGISTRY}"
RUN yarn install

FROM base AS builder

RUN apk update && apk add --no-cache git

ENV OPENAI_API_KEY=""
ENV GOOGLE_API_KEY=""
ENV CODE=""
ENV NEXT_PUBLIC_ENABLE_NODEJS_PLUGIN=1
# Disable webpack cache to avoid ENOSPC errors in CI
ENV NEXT_WEBPACK_USEPOLLING=false
ENV NEXT_PRIVATE_STANDALONE_BUILD=true

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Increase Node.js memory limit and disable webpack cache for Docker builds
RUN NODE_OPTIONS="--max-old-space-size=4096" yarn build

FROM base AS runner
WORKDIR /app

RUN apk add proxychains-ng

ENV PROXY_URL=""
ENV OPENAI_API_KEY=""
ENV GOOGLE_API_KEY=""
ENV CODE=""

COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/.next/server ./.next/server

EXPOSE 3000

CMD if [ -n "$PROXY_URL" ]; then \
    export HOSTNAME="0.0.0.0"; \
    protocol=$(echo $PROXY_URL | cut -d: -f1); \
    host=$(echo $PROXY_URL | cut -d/ -f3 | cut -d: -f1); \
    port=$(echo $PROXY_URL | cut -d: -f3); \
    conf=/etc/proxychains.conf; \
    echo "strict_chain" > $conf; \
    echo "proxy_dns" >> $conf; \
    echo "remote_dns_subnet 224" >> $conf; \
    echo "tcp_read_time_out 15000" >> $conf; \
    echo "tcp_connect_time_out 8000" >> $conf; \
    echo "localnet 127.0.0.0/255.0.0.0" >> $conf; \
    echo "localnet ::1/128" >> $conf; \
    echo "[ProxyList]" >> $conf; \
    echo "$protocol $host $port" >> $conf; \
    cat /etc/proxychains.conf; \
    proxychains -f $conf node server.js; \
    else \
    node server.js; \
    fi
