# db-parchapp

Repositorio de **persistencia** de ParchApp: esquema PostgreSQL, procedimientos almacenados, migraciones incrementales y archivos CSV usados para cargar datos de demostración (lugares, restaurantes, rutas y paradas).

## Contexto en el ecosistema

| Repositorio      | Rol                                      |
|------------------|------------------------------------------|
| `db-parchapp`    | Definición del modelo relacional y semilla |
| `back-parchapp`  | API que consume la BD y ejecuta el seed vía HTTP |
| `front-parchapp` | App móvil que consume la API             |

Stack acordado: **PostgreSQL** como SGBD, con entidades centrales de usuarios, establecimientos, rutas, reservas e intereses.

## Arquitectura del repositorio

```
db-parchapp/
├── docker-compose.yml          # PostgreSQL 16 en contenedor local
├── sql/
│   ├── parchapp_database_init.sql   # Esquema completo, vistas, funciones, roles
│   ├── migrations/
│   │   ├── 001_events_and_booking_functions.sql
│   │   └── 002_seed_populate_clear_dependents.sql
│   └── 004_create_reservations.sql  # Legado / no usado por el flujo actual
├── seed/csv/                   # Datos de ejemplo (origen del catálogo)
│   ├── lugares.csv
│   ├── restaurantes.csv
│   ├── rutas.csv
│   └── ruta_paradas.csv
└── parchapp.schema.dbml        # Diagrama del modelo (referencia)
```

### Modelo y roles

- El script `parchapp_database_init.sql` crea tablas, tipos enumerados, vistas, funciones de reservas, tablas *staging* (`stg_seed_*`) y el procedimiento `sp_populate_from_seed_staging()`.
- Rol de aplicación: `parchapp_app` (credenciales de desarrollo documentadas al final del script de init; usar la misma cadena en `DATABASE_URL` del backend).
- Roles adicionales previstos: `parchapp_readonly`, `parchapp_migration` (contraseñas `CHANGE_ME_*` en despliegues reales).

### Flujo de datos de semilla (importante)

> **El contenedor Docker arranca con una base de datos vacía de catálogo.** Solo se crea la base `parchapp` y el superusuario `postgres`; **no** se insertan automáticamente lugares, restaurantes ni rutas.

Orden recomendado en un entorno nuevo:

1. Levantar PostgreSQL (`docker compose up -d`).
2. Aplicar el esquema y migraciones SQL (pasos siguientes).
3. Levantar `back-parchapp` con `SEED_CSV_DIR` apuntando a `seed/csv`.
4. **Poblar datos** llamando a `POST /api/v1/sync/seed` en el backend (header `x-seed-secret`). Ese endpoint:
   - hace `COPY` de los CSV hacia las tablas `stg_seed_*`;
   - ejecuta `CALL sp_populate_from_seed_staging()`;
   - crea/actualiza el usuario `seed.catalog@parchapp.local` (contraseña demo: `DemoSeed2024!`).

También puedes disparar el mismo flujo desde la app móvil: pestaña **Ajustes** → **Sincronizar rutas y restaurantes** (requiere `EXPO_PUBLIC_SEED_SYNC_SECRET` alineado con el backend).

```bash
curl -X POST http://localhost:3000/api/v1/sync/seed \
  -H "x-seed-secret: dev_seed_sync_secret"
```

Si omites el paso 4, la app funcionará a nivel de esquema pero **sin establecimientos ni rutas de ejemplo**.

## Requisitos previos

- Docker y Docker Compose
- Cliente `psql` (o contenedor temporal con imagen `postgres:16-alpine`)
- Backend configurado para conectar con el rol `parchapp_app` (tras ejecutar el init)

## Comandos

### 1. Iniciar PostgreSQL

```bash
docker compose up -d
```

Puerto expuesto: `5432`. Credenciales del contenedor (superusuario):

- Usuario: `postgres`
- Contraseña: `postgres_dev_local`
- Base de datos: `parchapp`

Comprobar salud:

```bash
docker compose ps
```

### 2. Aplicar esquema inicial

Desde la raíz de este repositorio, con el contenedor en ejecución:

```bash
docker compose exec -T postgres psql -U postgres -d parchapp -v ON_ERROR_STOP=1 \
  < sql/parchapp_database_init.sql
```

O desde el host si tienes `psql` local:

```bash
PGPASSWORD=postgres_dev_local psql -h localhost -U postgres -d parchapp -v ON_ERROR_STOP=1 \
  -f sql/parchapp_database_init.sql
```

### 3. Aplicar migraciones (orden fijo)

```bash
for f in sql/migrations/001_events_and_booking_functions.sql \
         sql/migrations/002_seed_populate_clear_dependents.sql; do
  docker compose exec -T postgres psql -U postgres -d parchapp -v ON_ERROR_STOP=1 < "$f"
done
```

### 4. Poblar catálogo (primera vez y tras reset de volumen)

No basta con Docker: inicia `back-parchapp` y ejecuta el seed HTTP (ver README de `back-parchapp`) o el botón equivalente en `front-parchapp`.

### Detener y limpiar

```bash
# Detener contenedor
docker compose down

# Eliminar volumen (BD vacía de nuevo; repetir init + migraciones + POST /sync/seed)
docker compose down -v
```

## Conexión desde el backend

Ejemplo de `DATABASE_URL` (desarrollo local, rol de aplicación):

```env
DATABASE_URL="postgresql://parchapp_app:mK8pQ2vNx9wL4rT6!hJ@localhost:5432/parchapp"
```

La ruta absoluta a los CSV en el backend:

```env
SEED_CSV_DIR="/ruta/absoluta/a/db-parchapp/seed/csv"
```

## Mejoras futuras

- **Automatizar bootstrap**: script `make` o entrypoint que aplique init + migraciones en CI/CD (sin sustituir el seed vía API en entornos compartidos sin cuidado).
- **Migraciones versionadas**: herramienta tipo Flyway, Liquibase o `golang-migrate` en lugar de ejecución manual de archivos `.sql`.
- **Datos de producción**: separar seed de demostración de migraciones de datos reales; no exponer `sp_populate_from_seed_staging` en producción sin controles.
- **Backups y réplicas**: política de respaldo antes de abrir el portal de establecimientos.
- **Índices y rendimiento**: revisar consultas del generador de rutas cuando crezca el volumen de establecimientos.
- **Localización**: collation `es_CO.UTF-8` documentada en init para despliegues en Colombia.
- **Eliminar artefactos obsoletos**: revisar `sql/004_create_reservations.sql` (modelo UUID legado no alineado con el esquema actual).

## Referencias

- API y variable `SEED_CSV_DIR`: repositorio `back-parchapp`
- Invocación del seed desde la app: repositorio `front-parchapp`
