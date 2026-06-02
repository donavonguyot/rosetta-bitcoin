FROM eclipse-temurin:21-jdk AS build
WORKDIR /workspace
COPY pom.xml .
COPY src ./src
RUN apt-get update && apt-get install -y --no-install-recommends maven \
  && mvn -q -DskipTests package \
  && apt-get purge -y maven && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /workspace/target/jbitnode-0.1.0-SNAPSHOT.jar ./jbitnode.jar
ENV DATA_DIR=/data
VOLUME ["/data"]
ENTRYPOINT ["java", "-cp", "/app/jbitnode.jar"]
CMD ["com.jbitnode.cli.DbStatus"]
