# Spring Boot 멀티 스테이지 빌드 (초안)
# TODO: backend 파트가 build.gradle·gradlew 를 커밋하면 동작한다.
#       Java 버전이 21이 아니면 두 이미지 태그를 함께 수정할 것.
FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY backend/ ./
RUN ./gradlew bootJar --no-daemon

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
