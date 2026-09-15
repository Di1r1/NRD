# Развёртывание в Kubernetes

**Рекомендуемый способ — Helm-чарт в `helm/nrd-business-panel/`** (см. его
README.md): та же топология, что и ниже, плюс HPA (для web), 
PodDisruptionBudget, NetworkPolicy между всеми тремя сервисами, security-
контексты (allowPrivilegeEscalation: false, drop ALL capabilities,
seccompProfile RuntimeDefault) и параметризация через `values.yaml` под
разные окружения — то, чего не было в плоских манифестах ниже.

Плоские манифесты в этой папке (`00-namespace.yaml` … `06-ingress.yaml`)
остаются как более простой вариант без Helm — например, для быстрой
локальной проверки одной командой `kubectl apply -k .` без разбора values.
Оба варианта разворачивают идентичный набор объектов на уровне Deployment/
Service/PVC; чарт — их надмножество.

Манифесты в этой папке — перенос стенда из `docker-compose.yml` в k8s. Состав
сервисов и их назначение те же (см. `README.md` в корне репозитория, раздел
про Docker Compose), просто оформлены как k8s-объекты. Соответствие:

| docker-compose.yml   | k8s                                                      |
|-----------------------|-----------------------------------------------------------|
| `postgres` (сервис)   | `03-postgres.yaml` — StatefulSet + headless Service        |
| `backend` (сервис)    | `04-backend.yaml` — Deployment (1 реплика) + Service + PVC |
| `web` (сервис)        | `05-web.yaml` — Deployment (1 реплика) + Service            |
| volume `pgdata`       | volumeClaimTemplate в StatefulSet postgres                 |
| volume `backend_data` | PVC `backend-data` (ReadWriteOnce)                          |
| volume `nginx_certs`  | `emptyDir` в поде web (см. комментарий в 05-web.yaml)       |
| volume `nginx_logs`   | PVC `nginx-logs` (**ReadWriteMany** — см. предупреждение в 05-nginx-logs-pvc.yaml) |
| `ports: 18080:80, 443:443` | `06-ingress.yaml` (внешний домен) + Service `web` внутри кластера |
| `.env` (`POSTGRES_PASSWORD`, `APP_JWT_SECRET`) | Secret `adminpanel-secrets` (см. `01-secret.example.yaml`) |

## Порядок разворачивания

1. **Соберите и запушьте образы** в ваш registry (Dockerfile-ы не менялись —
   `backend/Dockerfile` и `frontend/Dockerfile` из корня репозитория подходят
   как есть):

   ```
   docker build -t <registry>/nrd-business-panel/backend:latest ./backend
   docker push <registry>/nrd-business-panel/backend:latest

   # frontend: сборка статики (npm ci && npm run build -> frontend/dist-prebuilt)
   # по-прежнему делается вручную ДО docker build, см. build_and_export.bat —
   # причина та же, что и раньше (см. комментарий в frontend/Dockerfile про
   # падение esbuild внутри контейнера на этой машине).
   docker build -f frontend/Dockerfile -t <registry>/nrd-business-panel/frontend:latest .
   docker push <registry>/nrd-business-panel/frontend:latest
   ```

   Поправьте `image:` в `04-backend.yaml` и `05-web.yaml`, если используете
   не `repo.dev002.local/nrd-business-panel/...`.

2. **Создайте namespace и секреты**:

   ```
   kubectl apply -f 00-namespace.yaml

   kubectl create secret generic adminpanel-secrets \
     -n nrd-business-panel \
     --from-literal=POSTGRES_PASSWORD='<случайный-пароль>' \
     --from-literal=APP_JWT_SECRET="$(openssl rand -hex 32)"
   ```

3. **Проверьте/впишите RWX StorageClass** в `05-nginx-logs-pvc.yaml` — без
   этого PVC `nginx-logs` не создастся (см. подробный комментарий в файле).

4. **Поправьте домен** в `06-ingress.yaml` (`host:` и `tls.hosts`) и
   заведите TLS-сертификат (`adminpanel-tls`) — через cert-manager или руками:

   ```
   kubectl create secret tls adminpanel-tls \
     -n nrd-business-panel \
     --cert=server.crt --key=server.key
   ```

5. **Примените остальные манифесты**:

   ```
   kubectl apply -k .
   # либо по одному, без kustomize:
   kubectl apply -f 02-configmap-app.yaml -f 02-configmap-nginx.yaml \
                 -f 03-postgres.yaml -f 04-backend.yaml \
                 -f 05-nginx-logs-pvc.yaml -f 05-web.yaml -f 06-ingress.yaml
   ```

## О чём стоит знать перед прод-эксплуатацией

- **backend и web намеренно `replicas: 1`.** Онлайн-статус пользователей
  хранится в памяти процесса backend (см. основной README, раздел про
  индикацию пользователей онлайн), а редактирование скриптов
  (`/admin/scripts`, `ScriptService.updateContent`) пишет файл + `.bak`
  напрямую на диск тома `backend-data`. Несколько реплик backend без
  доработки приложения (вынос онлайн-статуса в общее хранилище, блокировки
  при записи файлов) дадут рассинхронизацию. `web` можно масштабировать
  технически (при RWX-томе `nginx-logs`), но метрики размера статики
  (`nginx-metrics.json`) считаются независимо в каждом поде.
- **`nginx-logs` требует ReadWriteMany StorageClass.** Это самое вероятное
  место, где `kubectl apply` не заведётся "из коробки" в кластере без такого
  класса хранилища. См. альтернативу (переезд access-логов на
  stdout + кластерный логовый стек) в комментарии файла
  `05-nginx-logs-pvc.yaml`.
- **backend-контейнер стартует от root на долю секунды** (см.
  `backend/docker-entrypoint.sh`) и сам понижает привилегии до `appuser`.
  Если в кластере включён Pod Security Admission профиля `restricted`
  (требует `runAsNonRoot: true` на уровне пода), этот механизм не сработает —
  потребуется либо исключение для namespace, либо переделка Dockerfile.
- **TLS.** По умолчанию манифесты терминируют TLS на Ingress реальным
  сертификатом, а самоподписанный сертификат из `nginx/generate-cert.sh`
  внутри пода `web` остаётся неиспользуемым извне (генерируется в `emptyDir`,
  живёт до пересоздания пода). Если нужен end-to-end TLS до пода — см.
  комментарии в `06-ingress.yaml` и `05-web.yaml`.
- **HPA/autoscaling, PodDisruptionBudget, NetworkPolicy** — в этих плоских
  манифестах не добавлены, здесь только прямой перенос текущего стенда. Все
  они уже есть в Helm-чарте (`helm/nrd-business-panel/`) — используйте его,
  если это нужно, вместо ручного добавления сюда.

## CI/CD

Сборка образов и деплой через `helm upgrade` вынесены в `.gitlab-ci.yml` в
корне репозитория (job'ы `Build backend image`, `Build frontend image`,
`Deploy (helm upgrade)`, все — ручной запуск, `when: manual`, в дополнение к
уже существующему job'у зеркалирования с GitHub). См. комментарии в самом
файле — там же пояснение, почему сборка образов через kaniko, а не
Docker-in-Docker.
