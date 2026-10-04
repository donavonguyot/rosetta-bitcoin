# syntax=docker/dockerfile:1.7
FROM maven:3.9.11-eclipse-temurin-21 AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace/Nodes/Java
COPY Nodes/Java/pom.xml .
RUN --mount=type=cache,target=/root/.m2 \
  mvn -q -DskipTests dependency:go-offline
COPY Project/scripts/state_root.py Project/scripts/build_fixture_package.py /workspace/Project/scripts/
COPY Nodes/Shared/conformance/fixtures /workspace/Nodes/Shared/conformance/fixtures
COPY Nodes/Shared/testing/fixtures /workspace/Nodes/Shared/testing/fixtures
COPY Nodes/Java/fixture_resources.json .
COPY Nodes/Java/src ./src
RUN --mount=type=cache,target=/root/.m2 \
  mvn -q -DskipTests package

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /workspace/Nodes/Java/target/jbitnode-0.1.0-SNAPSHOT.jar ./jbitnode.jar
ENV DATA_DIR=/data
VOLUME ["/data"]
ENTRYPOINT ["java", "-cp", "/app/jbitnode.jar"]
CMD ["com.jbitnode.cli.DbStatus"]
