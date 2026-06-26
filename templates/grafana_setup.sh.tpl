#!/bin/bash
# ==============================================================================
# grafana_setup.sh.tpl — Script de instalación automática de Grafana
# Se ejecuta UNA SOLA VEZ cuando la EC2 arranca por primera vez (user_data)
# ==============================================================================

set -euo pipefail

# Redirigir todo el output a CloudWatch Logs para diagnóstico
exec > >(tee /var/log/grafana_setup.log) 2>&1
echo "=== Iniciando instalación de Grafana: $(date) ==="

# ── Paso 1: Actualizar el sistema ──────────────────────────────────────────
echo "[1/7] Actualizando paquetes del sistema..."
yum update -y

# ── Paso 2: Instalar herramientas necesarias ───────────────────────────────
echo "[2/7] Instalando dependencias..."
yum install -y wget curl jq amazon-cloudwatch-agent

# ── Paso 3: Instalar Grafana desde el repositorio oficial ─────────────────
echo "[3/7] Instalando Grafana OSS..."
cat > /etc/yum.repos.d/grafana.repo << 'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO

yum install -y grafana

# ── Paso 4: Configurar Grafana ─────────────────────────────────────────────
echo "[4/7] Configurando Grafana..."
cat > /etc/grafana/grafana.ini << EOF
[server]
http_port = 3000
domain = ${alb_dns_name}
root_url = %(protocol)s://%(domain)s:80/grafana/
serve_from_sub_path = true

[security]
admin_user = admin
admin_password = ${grafana_admin_password}
disable_initial_admin_creation = false
cookie_secure = false
cookie_samesite = lax

[auth.anonymous]
enabled = false

[log]
mode = console file
level = info

[analytics]
reporting_enabled = false
check_for_updates = false

[snapshots]
external_enabled = false
EOF

# ── Paso 5: Configurar datasource de CloudWatch automáticamente ────────────
echo "[5/7] Configurando datasource CloudWatch..."
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/cloudwatch.yml << EOF
apiVersion: 1
datasources:
  - name: CloudWatch
    type: cloudwatch
    access: proxy
    isDefault: true
    jsonData:
      authType: ec2_iam_role      # Usa el IAM Role de la instancia — sin credenciales hardcodeadas
      defaultRegion: ${aws_region}
      logsTimeout: 30m
    version: 1
    editable: false               # Evita modificaciones accidentales desde la UI
EOF

# ── Paso 6: Configurar CloudWatch Agent para enviar logs de Grafana ────────
echo "[6/7] Configurando CloudWatch Agent..."
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/grafana/grafana.log",
            "log_group_name": "${cloudwatch_log_group}",
            "log_stream_name": "grafana-app-{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/grafana_setup.log",
            "log_group_name": "${cloudwatch_log_group}",
            "log_stream_name": "grafana-setup-{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "${project_name}/Grafana",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"],
        "metrics_collection_interval": 60
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# ── Paso 7: Arrancar servicios ─────────────────────────────────────────────
echo "[7/7] Arrancando Grafana..."
systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server

# Verificar que Grafana respondió correctamente
sleep 15
if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
  echo "=== ✅ Grafana instalado y funcionando correctamente: $(date) ==="
  echo "=== URL: http://<ALB-DNS>/grafana ==="
  echo "=== Usuario: admin ==="
  echo "=== Datasource: CloudWatch (auto-configurado) ==="
else
  echo "=== ❌ Grafana no respondió al health check ==="
  journalctl -u grafana-server --no-pager -n 50
  exit 1
fi
