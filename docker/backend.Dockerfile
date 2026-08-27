# Spring Boot 멀티 스테이지 빌드 (Java 21 — backend/build.gradle toolchain 과 일치)
FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY backend/ ./
# Windows 에서 커밋된 파일은 실행 권한 비트가 빠지므로 빌드 시점에 부여한다.
# --mount=type=cache 로 gradle 의존성 캐시를 재사용해 재빌드 시간을 줄인다.
RUN --mount=type=cache,target=/root/.gradle \
    chmod +x gradlew && ./gradlew bootJar --no-daemon

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
