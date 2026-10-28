# Base images pinned by digest; Dependabot proposes updates as reviewed pull requests.
FROM maven:3.9.16-eclipse-temurin-17@sha256:1a352420f7aba21f5ad08df31bab55f74c013fb491f1ae8ab1dd7ff9ed698584 AS build
WORKDIR /build
# Dependencies in their own layer so source changes do not re-download them.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
# Tests run in CI before the image is built; this stage only packages.
RUN mvn -B -q -o package -DskipTests

FROM eclipse-temurin:17.0.20_8-jre-noble@sha256:39d618b8fda3408cfe792db2b666c0e3db8ea4ae263ab4d0c3805933e5355f45
WORKDIR /app
# Apply OS security updates published since the pinned base image was built.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*
# Unprivileged numeric UID so Kubernetes runAsNonRoot can verify it.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build --chown=root:root --chmod=0444 /build/target/transaction-service-1.0.0.jar app.jar
USER 10001

EXPOSE 8080

# Size the heap from the container memory limit rather than the host's.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/health"]

ENTRYPOINT ["java", "-jar", "app.jar"]
