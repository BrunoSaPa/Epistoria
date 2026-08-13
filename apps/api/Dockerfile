ARG NODE_IMAGE=node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03

FROM ${NODE_IMAGE} AS dependencies
WORKDIR /app
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/package.json
RUN npm ci --strict-allow-scripts

FROM dependencies AS build
COPY apps/api apps/api
RUN npm run build --workspace @epistoria/api

FROM dependencies AS production-dependencies
RUN npm prune --omit=dev

FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production \
    API_PORT=3000
WORKDIR /app
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=production-dependencies --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/apps/api/dist ./apps/api/dist
COPY --chown=node:node package.json ./package.json
COPY --chown=node:node apps/api/package.json ./apps/api/package.json
USER node
EXPOSE 3000
CMD ["node", "apps/api/dist/main.js"]

# This target retains the Prisma CLI for the explicit one-off release migration.
FROM build AS migrate
CMD ["npm", "run", "prisma:deploy", "--workspace", "@epistoria/api"]
