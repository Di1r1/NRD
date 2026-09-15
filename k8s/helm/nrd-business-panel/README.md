# Helm-чарт НРД - Бизнес панель

Полный перенос стенда из `docker-compose.yml` (см. корень репозитория) в
Kubernetes: postgres (StatefulSet), backend (Deployment), web/nginx
(Deployment), Ingress, плюс HPA/PodDisruptionBudget/NetworkPolicy/security-
контексты, которых не было в первой версии манифестов (`../..` — плоские
yaml, оставлены как более простой вариант без Helm).

## Установка

```
kubectl create namespace nrd-business-panel   # либо оставьте namespace.create=true в values.yaml

kubectl create secret generic adminpanel-secrets \
  -n nrd-business-panel \
  --from-literal=POSTGRES_PASSWORD='<случайный-пароль>' \
  --from-literal=APP_JWT_SECRET="$(openssl rand -hex 32)"

helm install adminpanel . \
  -n nrd-business-panel \
  --set image.registry=<ваш-registry>/nrd-business-panel \
  --set ingress.host=<ваш-домен> \
  --set nginxLogs.storageClassName=<ваш-RWX-storage-class> \
  --set postgres.storageClassName=<ваш-storage-class>
```

Обновление после изменений (новая версия образов, правки values):

```
helm upgrade adminpanel . -n nrd-business-panel -f values.yaml [--set ...]
```

Откат к предыдущему релизу:

```
helm rollback adminpanel -n nrd-business-panel
```

## Масштабирование backend

`backend.replicaCount` в values.yaml намеренно `1`. Причины — в основном
приложении, не в манифестах:

- Онлайн-статус пользователей хранится в `ConcurrentHashMap` в памяти
  процесса backend — при нескольких репликах каждый под будет видеть только
  часть залогиненных пользователей.
- Редактирование скриптов (`/admin/scripts`, `ScriptService.updateContent`)
  пишет файл и его `.bak`-копию прямо на диск тома `backend-data` — при
  параллельной записи с нескольких подов возможна гонка.

Чтобы безопасно увеличить `backend.replicaCount`, нужно сначала в коде
backend: вынести online-статус в общее хранилище (Postgres/Redis) и
сериализовать запись файлов скриптов (например, через файловую блокировку
или единый writer). Это отдельная задача уровня приложения — чарт её не
решает и не должен молча "чинить" сам.

## HPA для web

`web.autoscaling.enabled=false` по умолчанию. Включение требует, чтобы
`nginxLogs.storageClassName` указывал на реальный ReadWriteMany storage
class — иначе новые поды `web` на других узлах не смогут примонтировать том
`nginx-logs`, и HPA будет создавать поды, которые вечно висят в `Pending`.

## NetworkPolicy

Включены по умолчанию (`networkPolicy.enabled=true`) и разрешают только:
web ← Ingress-контроллер (namespace по `networkPolicy.ingressNamespaceLabel`,
проверьте реальный label вашего ingress-namespace через
`kubectl get ns --show-labels`), backend ← web, postgres ← backend. Если
после установки внешний доступ не работает — почти наверняка неверно указан
`ingressNamespaceLabel`.

## Секреты

По умолчанию (`secrets.create=false`) чарт не создаёт Secret вообще —
заведите его вручную командой выше (то же самое разделение, что и в
`.env.example` основного репозитория: реальные секреты не должны попадать
ни в git, ни в values-файл). `secrets.create=true` — для автоматизации из
CI, где значения приходят из защищённых CI/CD-переменных, а не коммитятся.

## Соответствие docker-compose.yml

| docker-compose.yml | Чарт |
|---|---|
| `postgres` | `templates/postgres.yaml` |
| `backend` | `templates/backend.yaml` |
| `web` | `templates/web.yaml` |
| volume `pgdata` | volumeClaimTemplate в StatefulSet postgres |
| volume `backend_data` | PVC `backend-data` |
| volume `nginx_certs` | `emptyDir` в поде web |
| volume `nginx_logs` | PVC `nginx-logs` (ReadWriteMany) |
| `ports: 18080:80, 443:443` | `templates/ingress.yaml` |
| `.env` | Secret `adminpanel-secrets` (заводится вручную, см. выше) |

## Чего в чарте всё ещё нет

- HPA/масштабирования backend (см. выше — требует правок в Java-коде).
- Интеграции с внешним secret-менеджером (Vault/External Secrets Operator) —
  используется обычный k8s Secret.
- CI/CD сборки образов — см. `.gitlab-ci.yml` в корне репозитория
  (job'ы `Build & push backend/frontend`, `Deploy (helm upgrade)`).
