# frontend 빌드 + nginx 서빙 (결정: Nginx가 정적 파일 직접 서빙)
# 빌드 컨텍스트는 저장소 루트: docker compose 의 context: .. 기준 경로다.
FROM node:20-alpine AS build
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

FROM nginx:1.27-alpine
COPY infra/nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
