# 🚀 SRE Process Service — Reto Técnico Lite Thinking 2026

**Autor:** Oscar Diaz
**Rol:** Platform & DevOps Engineer
**Infraestructura:** AWS — IaC con Terraform
**Región:** `us-east-1`

> Arquitectura desacoplada y altamente disponible de 4 capas desplegada como
> Infraestructura como Código (IaC). Procesa peticiones concurrentes mediante un
> backend elástico (EC2 + Lambda) protegido por una VPC privada y un ALB, con
> persistencia en RDS PostgreSQL y aceleración en memoria via Redis.

> **Decisión de arquitectura:** El estado de Terraform se almacena de forma remota en Amazon S3 con versionado y cifrado AES-256, y se utiliza DynamoDB para implementar state locking — evitando modificaciones concurrentes y asegurando la consistencia del estado en entornos de equipo y pipelines CI/CD.

> **Estado de Terraform almacenado remotamente en Amazon S3** con versionado y cifrado AES-256.
> **DynamoDB implementa State Locking** — evita modificaciones concurrentes y garantiza
> consistencia del estado en equipos y pipelines CI/CD.

---

## 📋 Tabla de Contenido

1. [¿Qué hace esta aplicación?](#-qué-hace-esta-aplicación)
2. [Arquitectura de 4 Capas](#️-arquitectura-de-4-capas)
3. [Estructura del Repositorio](#-estructura-del-repositorio)
4. [Pre-requisitos](#-pre-requisitos)
5. [Despliegue paso a paso](#-despliegue-paso-a-paso)
6. [Variables de configuración](#-variables-de-configuración)
7. [Outputs del despliegue](#-outputs-del-despliegue)
8. [Seguridad y IAM](#-seguridad-y-iam)
9. [Observabilidad](#-observabilidad)
10. [Decisiones de Arquitectura](#-decisiones-de-arquitectura)
11. [Respuestas Técnicas al Reto — Punto 1: Administración de Infraestructura](#-punto-1--administración-de-infraestructura)
12. [Respuestas Técnicas al Reto — Punto 2: Servicios de Red](#-punto-2--servicios-de-red)
13. [Respuestas Técnicas al Reto — Punto 3: Contenedores y Virtualización](#-punto-3--contenedores-y-virtualización)
14. [Respuestas Técnicas al Reto — Punto 4: Ciberseguridad Integrada](#-punto-4--ciberseguridad-integrada)
15. [Respuestas Técnicas al Reto — Punto 5: Gestión de Nube e IAM](#-punto-5--gestión-de-nube-e-iam)
16. [Respuestas Técnicas al Reto — Punto 6: Soporte 24/7 y Postmortem](#-punto-6--soporte-247-y-postmortem-itil)
17. [Respuestas Técnicas al Reto — Punto 7: Diseño de Infraestructura](#-punto-7--diseño-de-infraestructura-microservicios)
18. [Respuestas Técnicas al Reto — Punto 8: Respaldo y Recuperación](#-punto-8--políticas-de-respaldo-y-recuperación)
19. [Respuestas Técnicas al Reto — Punto 9: IaC y Automatización](#-punto-9--iac-y-automatización)
20. [Respuestas Técnicas al Reto — Punto 10: Monitoreo y Rendimiento](#-punto-10--monitoreo-y-optimización-de-rendimiento)
21. [Respuestas Técnicas al Reto — Punto 11: CI/CD](#-punto-11--buenas-prácticas-de-cicd)
22. [Respuestas Técnicas al Reto — Punto 12: Documentación](#-punto-12--documentación-y-mejora-continua)

---

## 🧠 ¿Qué hace esta aplicación?

La aplicación expone un endpoint HTTP que recibe cualquier payload JSON, lo procesa
aplicando un hash SHA-256, guarda el resultado en S3 y lo cachea en Redis por 60 segundos.

**Flujo de una petición (modo simple):**

```
Usuario
  │
  ▼
API Gateway HTTP  ──►  Lambda (Node.js)
                              │
                    ┌─────────┼─────────┐
                    ▼         ▼         ▼
                 Redis      RDS       S3
               (caché)  (PostgreSQL) (artefactos)
```

**¿Qué responde?**

- Si el payload ya fue procesado en los últimos 60s → responde desde Redis (`X-Cache: HIT`)
- Si es nuevo → procesa, guarda en S3, cachea en Redis → responde (`X-Cache: MISS`)

**Ejemplo rápido:**
```bash
curl -X POST https://<api-gateway-url>/process \
  -H "Content-Type: application/json" \
  -d '{"data": "hello world"}'
```

---

## 🏗️ Arquitectura de 4 Capas

### Capa 1 — Ingesta y Entrada Dual (Ingress Layer)

```
Internet
   │
   ├──► API Gateway (HTTP API v2)     → Serverless, baja latencia, throttling nativo
   │         └──► Lambda Processor
   │
   └──► Application Load Balancer     → HA multi-AZ, health checks, distribución inteligente
             └──► EC2 ASG (privadas)
```

| Componente | Tipo | Propósito |
|---|---|---|
| API Gateway HTTP v2 | Managed | Eventos, webhooks, peticiones directas |
| ALB | Managed | Entrada al tier de servidores EC2 |

### Capa 2 — Cómputo Híbrido y Elástico (Compute Layer)

```
┌────────────────────────────────────────────────┐
│              SUBNETS PRIVADAS                  │
│                                                │
│  Lambda (Serverless)    EC2 ASG (IaaS)         │
│  - Sin servidor         - t3.micro x2 (desired)│
│  - Escala a 0           - Min: 1 / Max: 4      │
│  - Paga por invocación  - CPU Target: 60%      │
│  - 256MB RAM / 15s      - Rolling refresh      │
└────────────────────────────────────────────────┘
```

### Capa 3 — Datos, Persistencia y Caché (Data & State Layer)

```
┌─────────────────────────────────────────────────────┐
│                  SUBNETS PRIVADAS                   │
│                                                     │
│  RDS PostgreSQL 16.3     Redis 7.1 (ElastiCache)    │
│  - db.t3.micro           - cache.t3.micro           │
│  - 20GB gp3 (→100GB)     - TTL: 60 segundos         │
│  - Cifrado en reposo     - Puerto 6379              │
│  - Backup 7 días         - Snapshot 1 día           │
│                                                     │
│  S3 (Object Storage)                               │
│  - AES256 cifrado        - Versioning ON            │
│  - Acceso solo via IAM   - Sin acceso público       │
└─────────────────────────────────────────────────────┘
```

### Capa 4 — Gobernanza, Seguridad y Observabilidad

```
VPC 10.40.0.0/16
├── Subnets Públicas  [10.40.0.0/24, 10.40.1.0/24]   → ALB, NAT Gateway
├── Subnets Privadas  [10.40.10.0/24, 10.40.11.0/24]  → Lambda, EC2, Redis, RDS
├── Internet Gateway  → Salida pública
├── NAT Gateway       → Salida de privadas hacia Internet (updates, AWS APIs)
└── VPC Endpoint S3   → Tráfico a S3 sin salir a Internet (gratis + seguro)

Security Groups (firewall por recurso, no por CIDR):
  ALB-SG     → Ingress 80/443 Internet  | Egress 8080 → EC2-SG
  EC2-SG     → Ingress 8080 ALB-SG     | Egress 6379 → Redis-SG, 5432 → RDS-SG
  Lambda-SG  → Egress 6379 Redis-SG    | Egress 5432 → RDS-SG, 443 Internet
  Redis-SG   → Ingress 6379 Lambda-SG  | Ingress 6379 EC2-SG
  RDS-SG     → Ingress 5432 EC2-SG     | Ingress 5432 Lambda-SG

IAM (Principio de Mínimo Privilegio):
  lambda-exec-role  → S3 (bucket propio), VPC, CloudWatch, X-Ray
  ec2-app-role      → SSM, CloudWatch Agent, X-Ray (scoped)
  rds-monitoring    → Solo RDS Enhanced Monitoring

Observabilidad:
  CloudWatch Logs   → API Gateway, Lambda, EC2, Grafana, CloudTrail (14 días retención)
  X-Ray Active      → Lambda tracing 100% invocaciones — Service Map visual
  CW Alarmas        → ALB 5xx, ASG CPU >80%, Lambda Errors >5/min
  CloudTrail        → Auditoría TODAS las llamadas API, multi-región, 90 días en S3
  GuardDuty         → Detección de amenazas ML 24/7, findings → SNS en 15 min
  Grafana           → Dashboard visual en EC2, datasource CloudWatch, acceso via ALB
  AWS Backup        → Snapshots diario/semanal RDS + EC2, vault cifrado AES-256
```

---

## 📁 Estructura del Repositorio

```
ProyectoDevops/
│
├── 📄 versions.tf         # Provider AWS ~5.0, Terraform >=1.6.0
├── 📄 data.tf             # Data sources: AZs, Account ID, Partition
├── 📄 variables.tf        # Todas las variables con descripción y validación
├── 📄 terraform.tfvars    # Valores de las variables para entorno dev
├── 📄 outputs.tf          # URLs, endpoints y ARNs post-despliegue
│
├── 📄 network.tf          # VPC, subnets, IGW, NAT, rutas, SGs, VPC Endpoint S3
├── 📄 apigateway.tf       # API Gateway HTTP v2, rutas, integración Lambda, logs
├── 📄 lambda.tf           # Función Lambda, CloudWatch Log Group, X-Ray
├── 📄 s3.tf               # Bucket resultados: cifrado, versionado, policy IAM
├── 📄 redis.tf            # ElastiCache Redis 7.1, subnet group
│
├── 📄 ec2_compute.tf      # ALB, Target Group, Launch Template, ASG, scaling policy
├── 📄 rds.tf              # RDS PostgreSQL 16.3, subnet group, SG, monitoring role
├── 📄 iam.tf              # Roles y políticas para Lambda
├── 📄 observability.tf    # IAM EC2, CloudWatch Logs, X-Ray policies, alarmas CW
├── 📄 cloudtrail.tf       # CloudTrail trail multi-región, S3 audit bucket, alarmas seguridad
├── 📄 guardduty.tf        # Amazon GuardDuty detector, SNS alerts, CW alarm
├── 📄 backup.tf           # AWS Backup vault, plan diario/semanal, alarma si falla
├── 📄 monitoring.tf       # Grafana EC2, IAM role, ALB rule, CloudWatch Dashboard
│
├── 📁 lambda/
│   ├── 📄 index.js        # Lógica de procesamiento: Redis cache + S3 + SHA-256
│   ├── 📄 server.js       # Versión Express.js para Docker/EC2 con /health endpoint
│   ├── 📄 index.test.js   # 7 tests unitarios + 2 de integración (Jest)
│   └── 📄 package.json    # Dependencias: Express, AWS SDK, Jest
│
├── 📄 Dockerfile          # Imagen multi-stage production-ready, usuario no-root
├── 📄 docker-compose.yml  # App + Redis + Redis Commander UI — un comando lo levanta todo
├── 📄 .dockerignore       # Excluye archivos sensibles de la imagen
│
├── 📁 k8s/
│   ├── 📄 namespace.yaml  # Espacio aislado para todos los recursos
│   ├── 📄 configmap.yaml  # Variables no sensibles (PORT, NODE_ENV, etc.)
│   ├── 📄 secret.yaml     # Variables sensibles cifradas en base64
│   ├── 📄 deployment.yaml # 2 réplicas, rolling update, anti-affinity, probes
│   ├── 📄 service.yaml    # LoadBalancer app + ClusterIP Redis
│   ├── 📄 hpa.yaml        # Autoscaler 2→10 pods por CPU/memoria
│   └── 📄 pvc.yaml        # Storage persistente EBS (Redis) + EFS (logs)
│
├── 📁 templates/
│   └── 📄 grafana_setup.sh.tpl  # Script instalación automática Grafana vía user_data
│
├── 📁 scripts/
│   ├── 📄 backup_test.sh    # Prueba automatizada de restore RDS con historial CSV
│   ├── 📄 health_check.sh   # 5 smoke tests del endpoint con validación latencia
│   └── 📄 deploy_local.sh   # start/stop/restart/logs/test del entorno Docker local
│
├── 📄 architecture.drawio  # Diagrama de arquitectura completo — abrir en draw.io
├── 📁 evidence/            # Capturas de pantalla del despliegue y pruebas
└── 📄 README.md            # Este archivo
```

---

## ✅ Pre-requisitos

Antes de desplegar necesitas tener instalado y configurado lo siguiente:

### 1. Herramientas locales

| Herramienta | Versión mínima | Verificar con |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.6.0 | `terraform version` |
| [AWS CLI](https://aws.amazon.com/cli/) | >= 2.x | `aws --version` |
| [Git](https://git-scm.com/) | cualquier | `git --version` |

### 2. Credenciales AWS configuradas

```bash
# Opción A — Variables de entorno (recomendado en CI/CD)
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"

# Opción B — AWS CLI configurado localmente
aws configure
# Ingresa: Access Key, Secret Key, Region (us-east-1), formato (json)

# Verificar que funciona
aws sts get-caller-identity
```

### 3. Permisos IAM necesarios en tu usuario/rol AWS

Tu usuario de AWS necesita permisos para crear:
- EC2, VPC, Subnets, Security Groups, ALB, ASG
- Lambda, API Gateway
- RDS, ElastiCache
- S3, IAM Roles/Policies
- CloudWatch, X-Ray

> Si eres administrador de la cuenta, ya los tienes. Si no, pide la política
> `AdministratorAccess` para el entorno de pruebas o una política personalizada
> con los servicios listados.

---

## 🚀 Despliegue paso a paso

### Paso 1 — Clonar el repositorio

```bash
git clone https://github.com/<tu-usuario>/ProyectoDevops.git
cd ProyectoDevops
```

### Paso 2 — Configurar la contraseña de RDS

La contraseña de la base de datos **nunca se hardcodea** en el código.
Se pasa como variable de entorno para que Terraform la tome de forma segura:

```bash
# Linux / macOS
export TF_VAR_db_password="MiPasswordSeguro123!"

# Windows CMD
set TF_VAR_db_password=MiPasswordSeguro123!

# Windows PowerShell
$env:TF_VAR_db_password = "MiPasswordSeguro123!"
```

> La contraseña debe tener al menos 8 caracteres. En producción, usa
> AWS Secrets Manager en lugar de variables de entorno.

### Paso 3 — Inicializar Terraform

Descarga los providers de AWS y Archive:

```bash
terraform init
```

Verás algo como:
```
Terraform has been successfully initialized!
```

### Paso 4 — Ver qué va a crear (plan)

```bash
terraform plan
```

Esto muestra todos los recursos que se van a crear **sin tocar nada aún**.
Es buena práctica revisarlo siempre antes de aplicar.

Deberías ver aproximadamente **50+ resources to add**.

### Paso 5 — Desplegar la infraestructura

```bash
terraform apply
```

Terraform te pedirá confirmación. Escribe `yes` y presiona Enter.

> ⏱️ El despliegue tarda entre **10-15 minutos** porque RDS y ElastiCache
> son los servicios más lentos en inicializar.

### Paso 6 — Obtener los endpoints

Al finalizar, Terraform imprime los outputs automáticamente:

```bash
terraform output
```

```
api_process_url  = "https://abc123.execute-api.us-east-1.amazonaws.com/process"
alb_dns_name     = "sre-process-service-dev-alb-123456.us-east-1.elb.amazonaws.com"
redis_endpoint   = "sre-process-service-dev-redis.abc.cache.amazonaws.com"
rds_endpoint     = "sre-process-service-dev-db.abc.us-east-1.rds.amazonaws.com"
results_bucket_name = "sre-process-service-dev-results-a1b2c3d4"
```

### Paso 7 — Probar el endpoint

```bash
# Reemplaza con tu URL del output api_process_url
curl -X POST https://<API_URL>/process \
  -H "Content-Type: application/json" \
  -d '{"data": "lite-thinking-2026", "test": true}'
```

**Primera llamada (Cache MISS):**
```json
{
  "id": "a3f9...",
  "processedAt": "2026-06-23T10:00:00.000Z",
  "algorithm": "sha256",
  "result": "b7c2...",
  "cacheKey": "process:a3f9...",
  "objectKey": "results/2026-06-23/a3f9....json"
}
```
El header de respuesta mostrará: `X-Cache: MISS`

**Segunda llamada inmediata (Cache HIT):**
El header de respuesta mostrará: `X-Cache: HIT` — respuesta desde Redis en <5ms.

### Paso 8 — Destruir la infraestructura (cuando termines)

```bash
terraform destroy
```

> ⚠️ Esto elimina **todos** los recursos creados. Úsalo solo cuando termines
> la prueba para evitar costos innecesarios.

---

## ⚙️ Variables de configuración

Todas las variables están definidas en `variables.tf` y sus valores en `terraform.tfvars`.

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `aws_region` | `us-east-1` | Región AWS de despliegue |
| `project_name` | `sre-process-service` | Prefijo de todos los recursos |
| `environment` | `dev` | Entorno (dev / qa / prod) |
| `vpc_cidr` | `10.40.0.0/16` | CIDR del bloque de red privado |
| `public_subnet_cidrs` | `10.40.0.0/24`, `10.40.1.0/24` | Subnets públicas (ALB, NAT) |
| `private_subnet_cidrs` | `10.40.10.0/24`, `10.40.11.0/24` | Subnets privadas (EC2, Lambda, RDS, Redis) |
| `ec2_instance_type` | `t3.micro` | Tipo de instancia EC2 en el ASG |
| `asg_min_size` | `1` | Mínimo de instancias EC2 |
| `asg_max_size` | `4` | Máximo de instancias EC2 |
| `asg_desired_capacity` | `2` | Instancias EC2 al arrancar |
| `db_engine` | `postgres` | Motor de base de datos |
| `db_engine_version` | `16.3` | Versión de PostgreSQL |
| `db_instance_class` | `db.t3.micro` | Tipo de instancia RDS |
| `db_allocated_storage` | `20` GB | Almacenamiento inicial RDS |
| `db_max_allocated_storage` | `100` GB | Límite de autoscaling de storage |
| `db_password` | *(sin default)* | **Pasar via `TF_VAR_db_password`** |
| `db_multi_az` | `false` | Multi-AZ para HA (activar en prod) |
| `redis_node_type` | `cache.t3.micro` | Tipo de nodo ElastiCache |
| `redis_ttl_seconds` | `60` | TTL de caché Redis en segundos |
| `log_retention_days` | `14` | Retención de logs en CloudWatch |

---

## 📤 Outputs del despliegue

| Output | Descripción |
|---|---|
| `api_process_url` | URL pública del endpoint `POST /process` en API Gateway |
| `alb_dns_name` | DNS público del Application Load Balancer |
| `alb_arn` | ARN del ALB (para configurar registros DNS en Route 53) |
| `asg_name` | Nombre del Auto Scaling Group |
| `redis_endpoint` | Endpoint interno de Redis (solo accesible desde la VPC) |
| `rds_endpoint` | Endpoint interno de RDS PostgreSQL |
| `rds_port` | Puerto de RDS (5432 para PostgreSQL) |
| `results_bucket_name` | Nombre del bucket S3 donde se guardan los artefactos |
| `ec2_app_role_arn` | ARN del IAM Role de las instancias EC2 |
| `ec2_log_group` | Nombre del Log Group de CloudWatch para la app EC2 |
| `cloudtrail_name` | Nombre del trail de auditoría CloudTrail activo |
| `cloudtrail_s3_bucket` | Bucket S3 donde se almacenan los logs de auditoría (90 días) |
| `cloudtrail_log_group` | Log Group de CloudWatch para búsqueda en tiempo real de eventos |
| `guardduty_detector_id` | ID del detector GuardDuty — verificar en consola AWS |
| `security_alerts_sns_arn` | ARN del SNS Topic para alertas GuardDuty + CloudTrail |
| `backup_vault_name` | Nombre del vault de AWS Backup (backups diarios y semanales) |
| `backup_plan_id` | ID del plan de backup activo |
| `grafana_url` | URL pública de Grafana via ALB — usuario: `admin` |
| `grafana_instance_id` | ID de la instancia EC2 donde corre Grafana |
| `cloudwatch_dashboard_url` | URL del dashboard de CloudWatch con métricas de toda la arquitectura |

---

## 🔐 Seguridad y IAM

### Principio de Mínimo Privilegio aplicado

Cada componente tiene su propio IAM Role con permisos **estrictamente necesarios**:

**Lambda (`lambda-exec-role`):**
- ✅ `AWSLambdaBasicExecutionRole` — logs en CloudWatch
- ✅ `AWSLambdaVPCAccessExecutionRole` — operar dentro de la VPC
- ✅ S3: solo `PutObject`, `GetObject`, `ListBucket` en **su bucket específico**
- ✅ X-Ray: solo `PutTraceSegments`, `PutTelemetryRecords`
- ❌ Sin acceso a otros buckets, sin acceso a RDS directamente, sin EC2

**EC2 (`ec2-app-role`):**
- ✅ `AmazonSSMManagedInstanceCore` — acceso sin necesidad de puerto 22 (SSH)
- ✅ `CloudWatchAgentServerPolicy` — métricas y logs del sistema operativo
- ✅ X-Ray: daemon en la instancia para trazas de rendimiento
- ✅ CloudWatch Logs: solo escribe en `/aws/ec2/sre-process-service-dev*`
- ❌ Sin acceso directo a S3, sin iam:*, sin acceso a otras cuentas

**RDS Monitoring (`rds-monitoring-role`):**
- ✅ Solo `AmazonRDSEnhancedMonitoringRole` — métricas de OS del motor RDS
- ❌ Sin ningún otro permiso

**CloudTrail (`cloudtrail-cw-role`):**
- ✅ Solo `logs:CreateLogStream` y `logs:PutLogEvents` en su log group específico
- ❌ Sin ningún otro permiso — no puede leer ni borrar los logs, solo escribir

### Segmentación de red (Zero Trust entre capas)

Ningún Security Group tiene reglas de entrada abiertas a `0.0.0.0/0` en
puertos internos. Cada regla referencia el **SG de origen** específico:

```
Internet → ALB-SG (80/443)
ALB-SG   → EC2-SG (8080)
EC2-SG   → Redis-SG (6379), RDS-SG (5432)
Lambda-SG→ Redis-SG (6379), RDS-SG (5432)
# Redis y RDS no tienen ninguna salida pública
```

### IMDSv2 obligatorio en EC2

El Launch Template fuerza `http_tokens = "required"`, lo que evita ataques
SSRF que intenten robar credenciales del metadata service de la instancia.

---

## 📊 Observabilidad

### CloudWatch Log Groups creados

| Log Group | Fuente | Retención |
|---|---|---|
| `/aws/lambda/sre-process-service-dev-processor` | Lambda | 14 días |
| `/aws/apigateway/sre-process-service-dev-http-api-access` | API Gateway | 14 días |
| `/aws/ec2/sre-process-service-dev-app` | EC2 App | 14 días |
| `/aws/ec2/sre-process-service-dev-system` | EC2 Sistema | 14 días |
| `/aws/ec2/sre-process-service-dev-grafana` | Grafana | 14 días |
| `/aws/cloudtrail/sre-process-service-dev` | CloudTrail tiempo real | 14 días |

---

### Grafana — Dashboard visual de toda la arquitectura

Grafana está desplegado en una instancia EC2 `t3.small` dentro de las subnets
privadas, accesible únicamente a través del ALB en la ruta `/grafana`.

Modo dummies: piensa en Grafana como el tablero de un avión. Todos los datos
de CloudWatch son los sensores — Grafana los convierte en gráficos visuales
que permiten ver de un vistazo si algo está fallando o si el sistema está
bajo presión.

**Acceso:** `http://<alb-dns>/grafana` — usuario `admin`

**Datasource configurado automáticamente:** CloudWatch vía IAM Role
(sin credenciales hardcodeadas — la instancia usa su propio rol para leer métricas)

**Dashboards disponibles al abrir Grafana:**

| Widget | Qué muestra | Por qué importa |
|---|---|---|
| Lambda Invocaciones | Peticiones por minuto | Volumen de tráfico en tiempo real |
| Lambda Errores + Duración | Fallos y tiempo de respuesta | Detecta degradación antes de que el usuario la sienta |
| Lambda Tasa de Error % | Errores / Invocaciones × 100 | SLA objetivo: <1% |
| EC2 CPU ASG | Promedio del grupo de instancias | Trigger del auto-scaling a 60% |
| ALB Peticiones + 5xx | Tráfico total y errores del servidor | Salud del balanceador |
| ALB Latencia p50/p95/p99 | Percentiles de tiempo de respuesta | p99 >1000ms indica problema |
| RDS CPU + Conexiones | Carga de la base de datos | Connection leaks o queries lentas |
| RDS Storage libre | GB disponibles | Alerta si baja de 5GB |
| Redis HITs vs MISSes | Efectividad del caché | HITs altos = buena configuración del TTL |

---

### AWS CloudTrail — Auditoría completa

CloudTrail es el registro permanente de toda la actividad en la cuenta AWS.
Cada acción queda registrada: quién la hizo, desde qué IP, a qué hora y qué resultado tuvo.

Modo dummies: es como el libro de registros de un edificio de oficinas.
Cada vez que alguien entra, sale o toca algo, queda escrito. Si algo sale mal,
se puede revisar exactamente qué pasó y cuándo.

**¿Qué captura el trail desplegado?**

| Tipo de evento | Ejemplo | Dónde se guarda |
|---|---|---|
| Gestión de recursos | `terraform apply`, crear EC2, modificar SG | S3 + CloudWatch Logs |
| Datos S3 | Acceso al bucket de resultados | S3 + CloudWatch Logs |
| IAM y STS globales | Asumir un rol, crear una política | S3 + CloudWatch Logs |
| Todas las regiones | Actividad en cualquier región AWS | S3 + CloudWatch Logs |

**Garantías de integridad:**
```hcl
enable_log_file_validation = true
# Genera un digest SHA-256 firmado por cada archivo de log.
# Si alguien modifica o borra un log después, el digest no coincide
# y la manipulación queda detectada automáticamente.
```

---

### Amazon GuardDuty — Detección de amenazas con ML

GuardDuty analiza continuamente CloudTrail, VPC Flow Logs y DNS logs usando
machine learning para detectar comportamiento anómalo — sin instalar agentes,
sin configurar reglas manualmente.

Modo dummies: si CloudTrail es la cámara de seguridad, GuardDuty es el guardia
inteligente que mira las cámaras y te avisa si algo parece sospechoso,
aunque nunca lo hayas visto antes.

**Ejemplos de lo que detecta en esta arquitectura:**

| Amenaza | Finding de GuardDuty | Acción |
|---|---|---|
| Credenciales robadas usadas desde otra IP | `UnauthorizedAccess:IAMUser/AnomalousBehavior` | SNS alert → investigar |
| EC2 contactando servidor de malware | `Trojan:EC2/DNSDataExfiltration` | SNS alert → aislar instancia |
| Acceso masivo a S3 inusual | `Discovery:S3/MaliciousIPCaller` | SNS alert → revisar bucket |
| Intento de fuerza bruta SSH | `UnauthorizedAccess:EC2/SSHBruteForce` | SNS alert → revisar SGs |

**Pipeline de alertas:**
```
GuardDuty detecta amenaza
        ↓
CloudWatch Event Rule (severidad ≥ 4 = Medium/High/Critical)
        ↓
SNS Topic security-alerts
        ↓
Email / Slack / PagerDuty (configurar suscripción en consola AWS)
```

---

### AWS Backup — Política centralizada de respaldos

AWS Backup gestiona los snapshots de RDS y EC2 desde un único punto de control,
con dos frecuencias según el tipo de necesidad.

Modo dummies: es como programar dos alarmas de respaldo — una diaria para
no perder más de 24 horas de trabajo, y una semanal para tener copias
históricas disponibles durante 3 meses.

| Plan | Horario | Retención | Uso |
|---|---|---|---|
| Diario | 02:00 AM UTC | 14 días | Recovery operacional rápido |
| Semanal | Domingos 03:00 AM UTC | 90 días | Auditorías y compliance |

Los backups van a un **vault cifrado con AES-256**. Si el job falla,
una alarma CloudWatch notifica inmediatamente.

---

### AWS X-Ray — Trazabilidad distribuida

La función Lambda tiene `tracing_config { mode = "Active" }` habilitado.
El 100% de las invocaciones generan una traza que muestra el tiempo exacto
en cada segmento: Redis GET → S3 PutObject → respuesta al cliente.

Modo dummies: X-Ray es como el GPS de una petición. Puedes ver exactamente
qué camino tomó, cuánto tardó en cada parada y dónde se atascó.

---

### Alarmas CloudWatch activas

| Alarma | Métrica | Umbral | Severidad |
|---|---|---|---|
| `*-alb-5xx-errors` | ALB HTTP 5xx | >10 en 2 min | Alta |
| `*-asg-cpu-high` | EC2 CPU promedio | >80% por 3 min | Media |
| `*-lambda-errors` | Lambda Errors | >5 en 1 min | Alta |
| `*-iam-policy-changes` | Cambios IAM (CloudTrail) | ≥1 en 5 min | Crítica |
| `*-unauthorized-api-calls` | AccessDenied repetidos | ≥5 en 5 min | Alta |
| `*-guardduty-high-severity` | GuardDuty findings | ≥1 en 5 min | Crítica |
| `*-backup-job-failed` | Jobs backup fallidos | ≥1 en 24h | Alta |

### Auto Scaling automático

El ASG tiene una política Target Tracking sobre CPU al 60%. AWS ajusta
el número de instancias de forma continua sin intervención manual:
- CPU sube → agrega una instancia cada 60 segundos
- CPU baja → elimina una instancia cada 120 segundos (espera 5 minutos antes)

---

## 📚 Respuestas Técnicas al Reto

---

### 🖥️ Punto 1 — Administración de Infraestructura

**EC2 configurado y gestionado en esta arquitectura:**

Se desplegaron instancias EC2 (Amazon Linux 2023, `t3.micro`) dentro de un Auto Scaling Group
en subnets privadas. No tienen IP pública. El acceso administrativo se realiza exclusivamente
via AWS Systems Manager Session Manager (SSM), eliminando la necesidad de SSH y llaves.

**Alta disponibilidad implementada:**

| Mecanismo | Configuración | Efecto |
|---|---|---|
| ALB multi-AZ | 2 subnets públicas en AZ-a y AZ-b | Si una AZ cae, el 100% del tráfico va a la otra |
| ASG min/desired/max | 1 / 2 / 4 | Siempre hay instancias activas, escalan automáticamente |
| Health checks ELB | Cada 30s, path `/health` | Instancias unhealthy se reemplazan sin intervención |
| Rolling refresh | `min_healthy_percentage = 50` | Updates sin downtime |
| RDS Multi-AZ (prod) | `db_multi_az = true` | Failover automático a réplica en ~60 segundos |

**Actualización de SO sin afectar el servicio (Rolling Update):**

```
1. Crear nueva AMI con el SO actualizado (patch aplicado)
2. Actualizar el Launch Template apuntando a la nueva AMI
3. Disparar Instance Refresh en el ASG:
   aws autoscaling start-instance-refresh \
     --auto-scaling-group-name sre-process-service-dev-asg \
     --preferences '{"MinHealthyPercentage": 50}'
4. El ASG termina y reemplaza instancias de a una:
   - Drena conexiones de la instancia (connection draining 30s)
   - Termina la instancia vieja
   - Lanza nueva instancia con AMI actualizada
   - Espera a que pase el health check del ALB
   - Continúa con la siguiente instancia
5. El ALB nunca envía tráfico a instancias en termination
```

**Entorno mixto Linux/Windows (respuesta teórica):**

Para un entorno híbrido Linux/Windows en AWS:

- **Active Directory**: desplegar AWS Managed Microsoft AD (servicio gestionado). Las instancias Windows se unen al dominio via `aws ssm send-command` con el documento `AWS-JoinDirectoryServiceDomain`.
- **Group Policies**: gestionadas desde el AD, se aplican automáticamente al reiniciar instancias del dominio.
- **Automatización con PowerShell**: AWS Systems Manager Run Command permite ejecutar scripts PowerShell en instancias Windows sin RDP:
  ```powershell
  # Ejemplo: forzar sincronización de GPO en todas las instancias Windows
  aws ssm send-command \
    --targets "Key=tag:OS,Values=Windows" \
    --document-name "AWS-RunPowerShellScript" \
    --parameters 'commands=["gpupdate /force"]'
  ```
- **Integración Linux**: las instancias Linux se autentican via SSSD+Kerberos contra el mismo AD, permitiendo usuarios de dominio en sistemas Linux.

---

### 🌐 Punto 2 — Servicios de Red

**Configuración de red AWS implementada:**

```
VPC: 10.40.0.0/16
│
├── Subnets PÚBLICAS (Internet-facing)
│   ├── public-1: 10.40.0.0/24  (AZ us-east-1a) — ALB, NAT Gateway
│   └── public-2: 10.40.1.0/24  (AZ us-east-1b) — ALB
│
├── Subnets PRIVADAS (Sin acceso directo desde Internet)
│   ├── private-1: 10.40.10.0/24 (AZ us-east-1a) — EC2, Lambda, Redis, RDS
│   └── private-2: 10.40.11.0/24 (AZ us-east-1b) — EC2, Lambda, Redis, RDS
│
├── Internet Gateway → Subnets públicas
├── NAT Gateway (public-1) → Subnets privadas (salida controlada)
└── VPC Endpoint S3 (Gateway) → Tráfico a S3 sin pasar por NAT
```

**Security Groups implementados (reglas por SG-source, no por CIDR):**

```
ALB-SG:
  Ingress: 0.0.0.0/0 → 80, 443   (tráfico web público)
  Egress:  ALB-SG → EC2-SG:8080   (solo hacia app tier)

EC2-SG:
  Ingress: ALB-SG → 8080          (solo desde el ALB)
  Egress:  EC2-SG → Redis-SG:6379
           EC2-SG → RDS-SG:5432
           EC2-SG → 0.0.0.0/0:443 (AWS APIs via NAT)

Lambda-SG:
  Egress:  Lambda-SG → Redis-SG:6379
           Lambda-SG → RDS-SG:5432
           Lambda-SG → 0.0.0.0/0:443

Redis-SG:
  Ingress: Lambda-SG → 6379
           EC2-SG → 6379

RDS-SG:
  Ingress: EC2-SG → 5432
           Lambda-SG → 5432
```

> **NACLs**: en esta arquitectura los Security Groups proporcionan el control
> granular necesario. Las NACLs están en su configuración default (allow all)
> como segunda línea de defensa. En producción se agregarían reglas NACL para
> bloquear rangos IP conocidos maliciosos a nivel de subnet.

**Diagnóstico de latencia multi-región (respuesta teórica):**

```
Paso 1 — MEDIR: CloudWatch → latencia p95/p99 por región
         Route 53 Health Checks → latency-based routing activo?

Paso 2 — AISLAR: ¿Latencia en DNS? → dig +trace <dominio>
                 ¿Latencia en red? → traceroute / MTR al endpoint
                 ¿Latencia en app? → X-Ray service map → identificar segmento lento

Paso 3 — SOLUCIONAR según causa:
  DNS lento      → Reducir TTL, usar Route 53 con latency routing
  Red lenta      → AWS Global Accelerator (anycast, enruta por backbone AWS)
  App lenta      → Revisar X-Ray traces → ¿Redis miss? ¿RDS slow query?
  CDN ausente    → Agregar CloudFront para assets estáticos

Paso 4 — PREVENIR: CloudWatch Alarms con threshold de latencia p99 > 500ms
```

**Servicios DNS, DHCP y FTP en Linux (respuesta teórica):**

```bash
# DNS — BIND9
apt install bind9
# /etc/bind/named.conf.local → definir zonas forward/reverse
# named-checkconf && systemctl restart bind9

# DHCP — isc-dhcp-server
apt install isc-dhcp-server
# /etc/dhcp/dhcpd.conf → subnet, range, routers, dns-servers
# systemctl enable --now isc-dhcp-server

# FTP seguro — vsftpd con TLS
apt install vsftpd
# /etc/vsftpd.conf: ssl_enable=YES, rsa_cert_file, pasv_min/max_port
# Abrir puertos 21 + rango pasivo en firewall (ufw allow 21/tcp)
```

---

**¿Cómo se garantiza la HA en esta arquitectura?**

- **ALB multi-AZ**: el balanceador opera en las dos subnets públicas (AZ-a y AZ-b).
  Si una AZ falla, el 100% del tráfico se redirige a la otra automáticamente.
- **ASG con mínimo 1 / deseado 2 / máximo 4**: siempre hay instancias en ambas AZs.
  Si una instancia falla el health check del ALB, el ASG la termina y levanta una nueva.
- **RDS con opción Multi-AZ**: en `terraform.tfvars` está `db_multi_az = false` para dev.
  En producción se cambia a `true` y AWS mantiene una réplica síncrona en otra AZ con
  failover automático en ~60 segundos.
- **ElastiCache Redis**: snapshot diario con retención de 1 día para recuperación rápida.
- **Lambda**: serverless y multi-AZ por diseño — AWS lo gestiona internamente.

**¿Cómo se actualiza el SO de los servidores sin afectar el servicio?**

El Launch Template tiene `instance_refresh { strategy = "Rolling" }` con
`min_healthy_percentage = 50`. Al actualizar la AMI:
1. Se actualiza el Launch Template con la nueva AMI
2. Se dispara un `instance refresh` en el ASG
3. AWS termina y reemplaza instancias de a una, manteniendo siempre al menos 50% operativo
4. El ALB deja de enviar tráfico a la instancia en termination antes de eliminarla (connection draining)

---

### Punto 2 — Servicios de Red y diseño de VPC

**Decisiones de segmentación de red:**

| Decisión | Razón |
|---|---|
| Subnets públicas solo para ALB y NAT | Los servidores de aplicación nunca exponen IPs públicas |
| Subnets privadas para EC2, Lambda, RDS, Redis | Aislamiento completo; solo accesibles desde dentro de la VPC |
| VPC Endpoint Gateway para S3 | El tráfico a S3 no sale a Internet, reduce costos de NAT y latencia |
| NAT Gateway centralizado en public[0] | Las instancias privadas pueden hacer updates/llamadas salientes sin IP pública |
| Security Groups por SG-source en vez de CIDR | Permite mover recursos entre subnets sin romper reglas de firewall |

---

### 🔒 Punto 3 — Contenedores y Virtualización

#### Entorno virtualizado — VMs locales desplegadas

Se configuraron y gestionaron dos máquinas virtuales en entorno local usando
**Oracle VirtualBox** y **VMware Workstation**, demostrando administración de
infraestructura virtualizada en un entorno mixto Linux/Windows:

**VM 1 — Ubuntu Server 22.04 LTS (VirtualBox)**

```bash
# Información del sistema verificada
oscardiaz@oscardiaz:~$ hostnamectl
  Static hostname: oscardiaz
  Virtualization: oracle          # Confirma que corre en VirtualBox
  Operating System: Ubuntu 22.04.5 LTS
  Kernel: Linux 5.15.0-157-generic
  Architecture: x86-64
  Hardware Model: VirtualBox

# Red configurada y activa
oscardiaz@oscardiaz:~$ ip addr
  # Interface enp0s3 con IP 192.168.1.94 — conectividad verificada
  # Docker instalado — interfaz docker0 visible (172.17.0.1/16)

# Sistema de archivos y usuarios
oscardiaz@oscardiaz:~$ ls -la
  # Directorio home con permisos correctos, historial bash activo
```

Esta VM representa el equivalente local de las instancias EC2 del ASG —
misma distribución (Ubuntu), misma arquitectura (x86-64), con Docker instalado
para ejecutar contenedores de la aplicación.

**VM 2 — Windows Server 2025 (VMware Workstation)**

```powershell
# Información del sistema
Microsoft Windows [Versión 10.0.26100.32238]
Hostname: oscardiaz

# Conectividad de red verificada
C:\Windows\System32> ping 8.8.8.8
  Paquetes: enviados = 4, recibidos = 4, perdidos = 0
  Latencia: mín = 18ms, máx = 107ms, media = 49ms

# Almacenamiento disponible
  Unidad C: Windows (SO principal)
  Unidad A: Disco de datos adicional
  Unidad D: DVD/ISO
```

Esta VM representa el servidor Windows del entorno mixto Linux/Windows —
útil para demostrar administración de Active Directory, Group Policies
y automatización con PowerShell en arquitecturas híbridas.

#### Gestión de almacenamiento persistente en contenedores

El almacenamiento persistente es uno de los retos más importantes en entornos
de contenedores porque, por defecto, los datos desaparecen cuando un contenedor
se reinicia o elimina.

La estrategia implementada en este proyecto cubre tres niveles:

**Nivel 1 — Docker local (docker-compose.yml)**

```yaml
# Los datos de Redis sobreviven reinicios del contenedor
volumes:
  redis_data:
    driver: local   # Volumen gestionado por Docker en el host
```

Cada vez que Redis reinicia, los datos siguen ahí porque están en el volumen,
no dentro del contenedor.

**Nivel 2 — Kubernetes en AWS EKS (k8s/pvc.yaml)**

```yaml
# PVC para Redis — almacenamiento dedicado por pod
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-pvc
spec:
  accessModes: [ReadWriteOnce]   # Un pod a la vez — ideal para Redis
  storageClassName: gp3          # AWS EBS gp3, aprovisionado automático
  resources:
    requests:
      storage: 5Gi

# PVC para logs compartidos entre múltiples pods
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-logs-pvc
spec:
  accessModes: [ReadWriteMany]   # Varios pods simultáneos — ideal para logs
  storageClassName: efs          # AWS EFS para acceso compartido
  resources:
    requests:
      storage: 10Gi
```

**Nivel 3 — Producción AWS**

| Necesidad | Solución | Por qué |
|---|---|---|
| Base de datos | RDS PostgreSQL | Managed, backups automáticos, Multi-AZ |
| Caché | ElastiCache Redis | Snapshot diario, no depende del contenedor |
| Artefactos | S3 | Durabilidad 99.999999999%, sin gestión |
| Logs pods | EFS (PVC ReadWriteMany) | Compartido entre todos los pods |
| Datos stateful | EBS gp3 (PVC ReadWriteOnce) | Dedicado por pod, alta performance |

---

### 🛡️ Punto 4 — Ciberseguridad Integrada

**Prácticas implementadas en esta arquitectura:**

**1. Firewall a nivel de instancia (Security Groups):**
Cada recurso tiene su propio SG con reglas de mínimo acceso. Ningún SG tiene
`0.0.0.0/0` en puertos internos. Ver sección de Seguridad y IAM para el detalle completo.

**2. IMDSv2 obligatorio en EC2:**
```hcl
metadata_options {
  http_tokens = "required"  # Previene ataques SSRF contra el metadata service
}
```

**3. Cifrado en tránsito y en reposo:**
- RDS: `storage_encrypted = true` (AES-256)
- S3: `sse_algorithm = "AES256"` + política que niega HTTP (solo HTTPS)
- Redis: tráfico confinado a la VPC privada
- API Gateway: solo HTTPS (TLS 1.2+)

**4. Sin credenciales en código:**
- Lambda usa IAM Execution Role (no Access Keys)
- EC2 usa Instance Profile (no Access Keys)
- `db_password` se pasa via variable de entorno `TF_VAR_db_password`, nunca en git

**5. Auditoría con AWS CloudTrail — IMPLEMENTADO en `cloudtrail.tf`:**

> 🔍 **Modo dummies:** Imagina que CloudTrail es el libro de visitas de tu
> infraestructura. Cada vez que alguien (o algo) toca un recurso AWS — ya sea
> Terraform, un usuario, o un servicio — CloudTrail anota quién fue, qué hizo,
> desde qué IP y a qué hora. Y los logs quedan guardados en S3 para que nadie
> los pueda borrar sin dejar rastro.

CloudTrail está desplegado con Terraform en `cloudtrail.tf` con estas garantías:

```hcl
# Trail activo multi-región con validación de integridad
resource "aws_cloudtrail" "main" {
  name                          = "sre-process-service-dev-trail"
  is_multi_region_trail         = true    # Cubre TODAS las regiones
  include_global_service_events = true    # IAM, STS incluidos
  enable_log_file_validation    = true    # Detecta tampering de logs
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.bucket
  cloud_watch_logs_group_arn    = "..."   # Búsqueda en tiempo real
}
```

Lo que queda registrado automáticamente:
- Todos los `terraform apply` que hiciste durante este reto
- Quién creó cada EC2, RDS, Lambda, S3 bucket
- Cambios en Security Groups y políticas IAM
- Intentos de acceso fallidos (`AccessDenied`)
- Accesos al bucket de resultados S3

**6. Reglas de firewall en VMs Linux (ufw):**
```bash
# En servidores Linux — política por defecto: denegar todo, permitir lo necesario
ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.40.0.0/16 to any port 8080  # Solo tráfico interno VPC
ufw allow from 10.40.0.0/16 to any port 5432  # PostgreSQL solo desde VPC
ufw enable
ufw status verbose
```

---

### ☁️ Punto 5 — Gestión de Nube e IAM

**RDS desplegado en esta arquitectura:**

| Parámetro | Valor | Justificación |
|---|---|---|
| Motor | PostgreSQL 16.3 | Estándar open-source, compatible con la mayoría de ORMs |
| Instancia | `db.t3.micro` | Suficiente para entorno dev/pruebas |
| Storage | 20GB gp3 → hasta 100GB auto | Autoscaling evita intervención manual |
| Cifrado en reposo | ✅ AES-256 | Requisito mínimo de seguridad |
| Acceso público | ❌ `publicly_accessible = false` | Solo accesible desde dentro de la VPC |
| Backup | 7 días, ventana 02:00-03:00 | Recovery Point Objective (RPO) de 24h |
| Multi-AZ | `false` en dev / `true` en prod | HA con failover automático en ~60s |
| Performance Insights | ✅ 7 días | Diagnóstico de queries lentas |
| Enhanced Monitoring | ✅ cada 60s | Métricas del OS del motor RDS |

**Estrategia IAM — Principio de Mínimo Privilegio:**

Cada componente tiene exactamente los permisos que necesita y **nada más**:

```
lambda-exec-role:
  ✅ AWSLambdaBasicExecutionRole  → CloudWatch Logs
  ✅ AWSLambdaVPCAccessExecutionRole → Operar en VPC
  ✅ s3:PutObject/GetObject/ListBucket → SOLO en su bucket
  ✅ xray:PutTraceSegments → SOLO envío de trazas
  ❌ Sin iam:*, Sin ec2:*, Sin rds:*

ec2-app-role:
  ✅ AmazonSSMManagedInstanceCore → Acceso SSM (sin SSH)
  ✅ CloudWatchAgentServerPolicy → Métricas y logs
  ✅ xray:PutTraceSegments → Trazas del daemon X-Ray
  ✅ logs:PutLogEvents → SOLO en /aws/ec2/sre-process-service-dev*
  ❌ Sin s3:*, Sin rds:*, Sin iam:*

rds-monitoring-role:
  ✅ AmazonRDSEnhancedMonitoringRole → SOLO métricas de monitoreo RDS
  ❌ Sin ningún otro permiso

cloudtrail-cw-role:
  ✅ logs:CreateLogStream  → SOLO en /aws/cloudtrail/sre-process-service-dev
  ✅ logs:PutLogEvents     → SOLO en /aws/cloudtrail/sre-process-service-dev
  ❌ Sin leer logs, sin borrar, sin acceso a otros log groups
```

**MFA para accesos críticos:**
En una arquitectura de producción se configurarían las siguientes políticas IAM
para forzar MFA en operaciones destructivas:
```json
{
  "Effect": "Deny",
  "Action": ["rds:DeleteDBInstance", "ec2:TerminateInstances", "s3:DeleteBucket"],
  "Resource": "*",
  "Condition": {
    "BoolIfExists": {"aws:MultiFactorAuthPresent": "false"}
  }
}
```

**Seguridad en arquitectura multinube (respuesta teórica):**

| Control | AWS | Equivalente Azure/GCP |
|---|---|---|
| Identidades federadas | AWS IAM Identity Center (SSO) | Azure AD / Google Workspace |
| Secrets centralizados | AWS Secrets Manager | Azure Key Vault / GCP Secret Manager |
| Auditoría unificada | CloudTrail → S3 → Athena | Enviar logs a SIEM central (Splunk/Datadog) |
| Cifrado de tráfico entre nubes | Site-to-Site VPN / AWS Direct Connect | ExpressRoute / Cloud Interconnect |
| Políticas de acceso | IAM con condition keys por IP/región | Conditional Access Policies |

---

### ⚡ Punto 6 — Soporte 24/7 y Postmortem ITIL

**Proceso de respuesta ante incidente crítico fuera de horario:**

```
1. DETECCIÓN    → Alarma CloudWatch → SNS → PagerDuty/SMS al ingeniero on-call
2. ACKNOWLEDGE  → Confirmar recepción en < 5 minutos (SLA P1)
3. TRIAGE       → ¿Afecta producción? ¿Cuántos usuarios? → P1/P2/P3
4. COMUNICAR    → Canal Slack #inc-YYYYMMDD | Notificar stakeholders ETA 30min
5. DIAGNOSTICAR → CloudWatch Logs + X-Ray traces + métricas ALB/ASG
6. MITIGAR      → Rollback, reinicio, failover según el caso
7. RESOLVER     → Corrección definitiva o plan temporal documentado
8. POSTMORTEM   → Documento formal dentro de las 48h siguientes
```

**Ejemplo real con esta arquitectura:**

> 02:30 AM — Lambda deja de responder. API Gateway devuelve 502.

```
02:30 → Alarma lambda-errors > 5 → SNS → PagerDuty
02:35 → Ingeniero confirma alerta
02:37 → X-Ray muestra timeout en conexión Redis (3000ms exceeded)
02:40 → ElastiCache reiniciado por ventana de mantenimiento no coordinada
02:42 → Cluster Redis auto-recuperado. Servicio restaurado.
02:50 → Incidente cerrado. Duración: 20 min. SLA afectado: < 1%
03:00 → Comunicación de cierre a stakeholders
```

**Postmortem (formato ITIL):**

```
INCIDENTE: INC-2026-001 | Severidad: P2 | Duración: 20 min
CAUSA RAÍZ: Ventana de mantenimiento ElastiCache no ajustada a horario de verano
IMPACTO: ~240 peticiones fallidas. SLA mensual: 99.94% (objetivo: 99.9% ✅)
CORRECTIVAS: Actualizar maintenance_window + retry con backoff en Lambda
PREVENTIVAS: Circuit breaker para Redis + ElastiCache Serverless en evaluación
```

---

### 🏛️ Punto 7 — Diseño de Infraestructura Microservicios

Los manifiestos en `k8s/` definen una arquitectura de microservicios lista para
desplegarse en cualquier cluster Kubernetes (EKS, GKE, AKS o bare-metal).

**Cloud PaaS — AWS EKS:**
```
Internet → CloudFront → ALB → EKS Cluster
                               ├── Deployment (2 réplicas, rolling update)
                               ├── HPA (2→10 pods, CPU 60% + RAM 70%)
                               ├── Service (LoadBalancer)
                               └── PVC (EBS gp3 + EFS)
                    Managed services: RDS + ElastiCache + S3 + ECR
```

**On-Premise — kubeadm + VMware:**
```
Firewall → HAProxy/MetalLB → Kubernetes (kubeadm)
           Master Nodes x3 (HA etcd)
           Worker Nodes (VMware VMs)
           Storage: Longhorn/Ceph | Registry: Harbor
           Monitoreo: Prometheus + Grafana + Alertmanager
```

**Cloud IaaS — EC2 self-managed:**
```
ALB → EC2 ASG (esta arquitectura actual)
      Docker Engine + Kubernetes (kubeadm)
      EBS Volumes (PersistentVolumes)
      EFS (almacenamiento compartido)
```

---

### 💾 Punto 8 — Políticas de Respaldo y Recuperación

AWS Backup gestiona todos los snapshots desde `backup.tf` con dos frecuencias:

| Plan | Horario | Retención | RPO | RTO |
|---|---|---|---|---|
| Diario | 02:00 UTC | 14 días | 24h | ~15 min |
| Semanal | Domingos 03:00 UTC | 90 días | 7 días | ~15 min |
| RDS PITR | Continuo | 7 días | 5 min | ~30 min |

**Prueba mensual automatizada de restore:**

```bash
# scripts/backup_test.sh — ejecutar el primer domingo de cada mes
bash scripts/backup_test.sh
# Restaura el snapshot más reciente en instancia temporal
# Valida integridad de la base de datos
# Elimina instancia temporal (evita costos)
# Guarda resultado en scripts/backup_test_history.csv
```

---

### ⚙️ Punto 9 — IaC y Automatización

Toda la infraestructura está definida como código en 16 archivos `.tf` con
más de 65 recursos AWS. El proceso de despliegue es completamente reproducible:

```bash
# Mismo comando despliega entornos idénticos en dev, qa o prod
export TF_VAR_db_password="password" && terraform apply
```

**Ventajas concretas sobre el ClickOps manual:**

| ClickOps | Terraform |
|---|---|
| Pasos olvidados en la consola | Estado deseado completamente declarado |
| Configuraciones inconsistentes | Mismo código = entornos idénticos |
| Sin historial de cambios | `git log` es el historial completo |
| Difícil recuperación ante desastres | `terraform apply` recrea todo en 15 min |
| Sin revisión de pares | Pull Request obligatorio antes de aplicar |

---

### 📈 Punto 10 — Monitoreo y Optimización de Rendimiento

**Herramientas implementadas:**

| Herramienta | Tipo | Qué cubre |
|---|---|---|
| **Grafana** | Dashboard visual | Métricas de toda la arquitectura en tiempo real |
| **AWS CloudWatch** | Métricas + Logs + Alarmas | Todas las capas de la arquitectura |
| **AWS X-Ray** | Trazas distribuidas | Latencia por segmento end-to-end |
| **GuardDuty** | Seguridad ML | Amenazas y comportamiento anómalo |
| **CloudTrail** | Auditoría | Toda la actividad de la cuenta AWS |

**Métricas clave en producción:**

| Métrica | Umbral de alerta | Acción automática |
|---|---|---|
| ALB HealthyHostCount | < 1 | P1 inmediato |
| ALB HTTP 5xx | > 10/min | P2 investigar |
| ALB TargetResponseTime p99 | > 1000ms | P2 optimizar |
| ASG CPUUtilization | > 60% | Auto-scale up |
| Lambda Errors | > 5/min | P2 revisar logs |
| RDS FreeStorageSpace | < 5GB | P2 ampliar |
| ElastiCache CacheMisses | > 80% | P3 revisar TTL |

**Auto-scaling sin intervención manual:**

Cuando el CPU del ASG supera el 60% durante 2 períodos de 60 segundos,
la política Target Tracking lanza instancias nuevas automáticamente.
Cuando el CPU baja, las elimina con una ventana de estabilización de
5 minutos para evitar oscilaciones.

---

### 🔄 Punto 11 — Buenas Prácticas de CI/CD

**CI vs CD — diferencia clave:**

| CI — Integración Continua | CD — Entrega Continua |
|---|---|
| Corre en cada commit/PR | Corre al mergear a main |
| Valida que el código no rompe nada | Lleva el código validado a producción |
| Build → Test → Lint → Scan | Deploy DEV → QA → PROD |
| Detecta errores temprano | Automatiza el proceso de release |

**Pipeline implementado en `.github/workflows/`:**

```
commit → PR → CI (tests + docker build + terraform validate + tfsec)
                    ↓ merge a main
              CD DEV (automático + smoke test)
                    ↓ aprobación manual
              CD PROD (gate + smoke test + rollback si falla)
```

**Notificaciones de fallo:** el job `notify-failure` en `ci.yml` reporta
el commit, rama y actor cuando cualquier step falla, con enlace directo
al run de GitHub Actions.

---

### 📝 Punto 12 — Documentación y Mejora Continua

Documentar cada cambio en la infraestructura es tan importante como el
cambio mismo. Sin documentación, la infraestructura se convierte en una
caja negra que solo entiende quien la creó.

**Prácticas aplicadas en este proyecto:**

- Cada archivo `.tf` tiene comentarios explicando el **por qué**, no solo el qué
- Las variables tienen `description` con justificación del valor elegido
- Este README se actualiza con cada cambio arquitectónico antes del merge
- Los outputs de Terraform son la fuente de verdad de los endpoints activos
- La carpeta `evidence/` contiene capturas de cada etapa del despliegue
- El archivo `architecture.drawio` refleja la arquitectura actual desplegada

---

## 🎯 Decisiones de Arquitectura

### ¿Por qué Redis TTL de 60 segundos?

60 segundos es un balance deliberado entre dos fuerzas opuestas:
- **Muy corto (<10s)**: el caché no ayuda, casi todo pasa directo a RDS
- **Muy largo (>300s)**: datos desactualizados pueden ser servidos a usuarios

Para este servicio de procesamiento con payloads únicos (SHA-256), 60 segundos
evita el re-procesamiento de peticiones duplicadas en ráfagas de tráfico
(ej: un cliente que reintenta por timeout) sin comprometer la frescura de datos.

### ¿Por qué dos puntos de entrada (API Gateway + ALB)?

- **API Gateway** es ideal para peticiones event-driven de baja concurrencia con
  necesidad de throttling nativo, autenticación y transformaciones de payload.
- **ALB** es ideal para aplicaciones de larga ejecución, WebSockets, conexiones
  persistentes y workloads que requieren servidores con estado.
  
Al tener ambos, la arquitectura soporta casos de uso distintos sin comprometer
el diseño de ninguno de los dos.

### ¿Por qué VPC Endpoint para S3?

Sin el endpoint, el tráfico Lambda → S3 saldría por el NAT Gateway (costo adicional)
y por Internet (latencia + superficie de ataque). El Gateway Endpoint redirige ese
tráfico internamente dentro de AWS sin costo adicional y con mejor latencia.

### ¿Por qué no SSH en las EC2?

Las instancias EC2 usan **AWS Systems Manager Session Manager** (SSM) para acceso
administrativo. Esto elimina:
- La necesidad de un Security Group con puerto 22 abierto
- La gestión de par de llaves SSH
- El riesgo de llaves comprometidas o expiradas

El acceso a la instancia queda auditado en CloudTrail automáticamente.

### Remote State — S3 + DynamoDB State Locking

El estado de Terraform se almacena de forma remota en Amazon S3 y se utiliza
DynamoDB para implementar state locking, evitando modificaciones concurrentes
y asegurando la consistencia del estado.

**Bucket S3:** `sre-process-service-tfstate-440744252164`
- Versionado habilitado — recuperación de versiones anteriores del estado
- Cifrado AES-256 en reposo
- Solo HTTPS — bucket policy niega HTTP

**Tabla DynamoDB:** `sre-process-service-tf-locks`
- Antes de cada `terraform apply`, Terraform escribe un lock con: quién, cuándo y qué operación
- Si otro proceso intenta ejecutar simultáneamente, detecta el lock y falla con error claro
- Al terminar, el lock se libera automáticamente
- Si el proceso se interrumpe: `terraform force-unlock <LOCK_ID>`

Esto garantiza que múltiples ingenieros y pipelines de CI/CD puedan trabajar
sobre la misma infraestructura de forma segura y coordinada.

---

## 📞 Contacto

**Oscar Diaz** — Platform & DevOps Engineer
Reto Técnico Lite Thinking 2026

---

*Infraestructura desplegada con ❤️ y Terraform en AWS us-east-1*
