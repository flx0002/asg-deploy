# Multi-stage build for WntASG Console
# Stage 1: Build backend (frontend is pre-built on host)
FROM docker.m.daocloud.io/library/eclipse-temurin:21-jdk AS builder

WORKDIR /build

# Copy maven wrapper and pom files first for better caching
COPY backend/mvnw .
COPY backend/.mvn .mvn/
COPY backend/pom.xml .
COPY backend/sdk/pom.xml sdk/pom.xml
COPY backend/console/pom.xml console/pom.xml

# Download dependencies (cached layer)
RUN ./mvnw dependency:go-offline -Dmaven.test.skip=true -Dpmd.skip=true -Dcheckstyle.skip=true -Dgpg.sign.skip=true -Denforcer.skip=true -Dlombok.delombok.skip=true -Dmaven.javadoc.skip=true -Dmaven.source.skip=true 2>&1 || true

# Copy backend source code
COPY backend/ .

# Copy pre-built frontend into backend static resources (skip frontend-maven-plugin)
COPY frontend/build/ console/src/main/resources/static/

# Build the project (skip frontend build, checkstyle, etc.)
RUN ./mvnw clean package -Dmaven.test.skip=true -Dpmd.skip=true -Dcheckstyle.skip=true -Dgpg.sign.skip=true -Denforcer.skip=true -Dlombok.delombok.skip=true -Dmaven.javadoc.skip=true -Dmaven.source.skip=true -Dapp.build.dev=false -Dskip.frontend=true

# Stage 2: Runtime image
FROM docker.m.daocloud.io/library/eclipse-temurin:21-jre

LABEL maintainer="WntASG Team"
LABEL description="WntASG Console - Security Gateway Management"
LABEL version="0.0.1-SNAPSHOT"
LABEL product="WntASG"

WORKDIR /app

COPY --from=builder /build/console/target/higress-console.jar /app/higress-console.jar
COPY backend/start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV JAVA_OPTS="-Xms512m -Xmx2g"
ENV SERVER_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/app/start.sh"]
