# Многоэтапная сборка backend.
FROM repo.dev002.local/dockerio/library/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

FROM repo.dev002.local/dockerio/library/eclipse-temurin:21-jre-jammy
WORKDIR /app
# pwsh (PowerShell Core) временно не устанавливается: в build-среде нет
# доступа к packages.microsoft.com. Вернуть после появления внутреннего
# зеркала Microsoft-пакетов. Фича с .ps1-скриптами без pwsh не работает.
RUN apt-get update && apt-get install -y --no-install-recommends python3 bash \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/target/admin-panel-backend.jar app.jar
COPY docker-entrypoint.sh /app/docker-entrypoint.sh

# Непривилегированный пользователь для запуска java-процесса. Раньше backend работал
# от root — при том, что это приложение по своей природе выполняет загруженные
# администратором скрипты как есть (см. ScriptService), запуск от root означал, что
# любой баг в контроле доступа к загрузке скриптов (см. аудит безопасности) сразу
# давал атакующему root в контейнере.
RUN mkdir -p /app/data && chmod +x /app/docker-entrypoint.sh && groupadd -r appuser && useradd -r -g appuser -d /app -s /usr/sbin/nologin appuser
EXPOSE 8080
# entrypoint стартует от root только на долю секунды, чтобы поправить владельца
# тома /app/data (см. docker-entrypoint.sh), и сразу передаёт управление java
# от имени appuser — постоянно root внутри контейнера не работает.
ENTRYPOINT ["/app/docker-entrypoint.sh"]
