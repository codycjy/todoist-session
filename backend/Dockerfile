FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json drizzle.config.ts ./
COPY drizzle ./drizzle
COPY src ./src
ENV DB_PATH=/data/session.db
VOLUME /data
EXPOSE 8787
CMD ["npx", "tsx", "src/index.ts"]
