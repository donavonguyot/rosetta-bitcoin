# syntax=docker/dockerfile:1.7
FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /workspace
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 \
  mvn -q -DskipTests dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 \
  mvn -q -DskipTests package

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /workspace/target/jbitnode-0.1.0-SNAPSHOT.jar ./jbitnode.jar
ENV DATA_DIR=/data
VOLUME ["/data"]
ENTRYPOINT ["java", "-cp", "/app/jbitnode.jar"]
CMD ["com.jbitnode.cli.DbStatus"]
