FROM node:26.12.1-bookworm-slim@sha256:88e480776c6149ff1d098cd304f44bf18057fb5d284a3329b78162d29821e28c AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY patches/ patches/
COPY scripts/ scripts/
RUN node scripts/prepare-runtime.mjs

FROM node:26.12.1-bookworm-slim@sha256:88e480776c6149ff1d098cd304f44bf18057fb5d284a3329b78162d29821e28c
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/node_modules/ node_modules/
COPY --from=build --chmod=0755 /app/.runtime/bin/wx /usr/local/bin/wx
COPY bin/ bin/
COPY --chown=node:node workspace/ workspace/
RUN install -d -m 0700 -o node -g node /app/.runtime
ENV LUMEEBOT_WX_BINARY=/usr/local/bin/wx
USER node
ENTRYPOINT ["node", "bin/bot.mjs"]
CMD ["start"]
