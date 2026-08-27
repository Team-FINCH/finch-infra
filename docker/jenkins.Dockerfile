# Jenkins + docker CLI.
# 호스트의 /var/run/docker.sock 을 마운트해 호스트 Docker 로 빌드한다.
# → 빌드된 이미지가 곧바로 호스트 로컬 저장소에 생겨 레지스트리가 필요 없다 (결정서 참고).
FROM jenkins/jenkins:lts-jdk21
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*
# docker.sock 권한 문제를 피하려고 compose 에서 user: root 로 실행한다 (README 참고).
