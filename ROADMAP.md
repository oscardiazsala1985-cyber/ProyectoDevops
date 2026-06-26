# 🤖 Roadmap — Evolución de Arquitectura
## SRE Process Service — Próximas Capacidades

**Autor:** Oscar Diaz | Platform & DevOps Engineer
**Estado:** Diseño propuesto — listo para implementación

---

## 🧠 Visión General

La arquitectura actual cubre infraestructura, seguridad y observabilidad.
La siguiente evolución incorpora **automatización inteligente con IA** y
**gestión operacional autónoma** mediante un agente llamado **@Evita**.

> Modo dummies: si hoy la infraestructura te avisa cuando algo falla,
> mañana @Evita lo diagnostica, lo documenta en Jira y te notifica en Slack
> — sin que nadie intervenga manualmente.

---

## 🤖 Evolución 1 — Agente @Evita (AIOps Bot)

### ¿Qué es @Evita?

**Modo dummies:** Es un asistente virtual en Slack que vive conectado
a toda la infraestructura AWS. Cuando GuardDuty detecta una amenaza,
cuando una Lambda falla, o cuando un certificado va a vencer —
@Evita lo sabe, lo documenta en Jira y te avisa en el canal correcto.

**Modo senior:** Agente AIOps construido sobre AWS Lambda + Amazon Bedrock
(Claude) con integraciones a Slack Webhooks, Jira REST API y AWS EventBridge.
Implementa el patrón Event-Driven AIOps — cada evento de seguridad u
operacional dispara una cadena de automatización sin intervención humana.

### Arquitectura de @Evita

```
AWS EventBridge
      │
      ├── GuardDuty Finding     ─────────────────────────────┐
      ├── CloudWatch Alarm                                    │
      ├── Lambda Error                                        ▼
      └── Certificate Expiry              Lambda @Evita-Processor
                                                │
                                    ┌───────────┼───────────┐
                                    ▼           ▼           ▼
                              Slack API    Jira REST    Bedrock
                              (notifica)  (crea ticket) (analiza
                                                         con IA)
```

### Canales Slack de @Evita

| Canal | Propósito |
|---|---|
| `#devops-security` | Findings de GuardDuty + alarmas IAM |
| `#devops-monitoring-audit` | CloudTrail events críticos |
| `#devops-monitoring-certificados` | Alertas de certificados próximos a vencer |
| `#devops-incidents` | Incidentes P1/P2 con timeline automático |
| `#devops-faqs` | Respuestas automáticas de @Evita via Bedrock |

### Flujo GuardDuty → Slack → Jira

```
1. GuardDuty detecta amenaza (ej: puerto abierto en EC2)
2. EventBridge captura el finding en tiempo real
3. Lambda @Evita-Processor:
   a. Formatea el mensaje con severidad y descripción
   b. Publica en #devops-security vía Slack Webhook
   c. Consulta Knowledge Base en Bedrock para contexto
   d. Crea ticket en Jira con:
      - Título: tipo de finding
      - Descripción: análisis automático
      - Prioridad: según severidad GuardDuty
      - Asignado: arquitecto responsable
      - Etiquetas: security, guardduty, auto-generated
4. Responde en el hilo de Slack con el link del ticket Jira
```

### Código Lambda @Evita (Node.js)

```javascript
// evita-processor/index.js
const { GuardDutyClient } = require('@aws-sdk/client-guardduty');
const { BedrockRuntimeClient, InvokeModelCommand } = require('@aws-sdk/client-bedrock-runtime');

exports.handler = async (event) => {
  const finding = event.detail;

  // 1. Analizar con Bedrock (Claude)
  const analysis = await analyzeWithBedrock(finding);

  // 2. Notificar en Slack
  await notifySlack({
    channel: '#devops-security',
    finding: finding,
    analysis: analysis
  });

  // 3. Crear ticket en Jira
  const ticket = await createJiraTicket({
    summary: `🚨 GuardDuty: ${finding.type}`,
    description: analysis,
    priority: mapSeverityToPriority(finding.severity),
    labels: ['security', 'guardduty', 'auto-generated']
  });

  return { ticketId: ticket.key };
};
```

---

## 🔐 Evolución 2 — Monitor de Certificados SSL

### ¿Qué hace?

**Modo dummies:** Es como una alarma de calendario para certificados SSL.
35 días antes de que venza un certificado, una Lambda escanea el bucket S3
donde están guardados, calcula los días restantes y automáticamente crea
un ticket en Jira y envía un correo al arquitecto responsable.

**Modo senior:** Lambda con EventBridge Schedule (cron diario) que lista
objetos en S3 con extensiones .cer/.p12/.jks/.pem, extrae la fecha de
expiración usando el módulo crypto de Node.js, y dispara notificaciones
multi-canal para certificados con menos de 35 días de vigencia.

### Arquitectura

```
EventBridge Schedule (diario 06:00 AM)
        │
        ▼
Lambda cert-monitor
        │
        ├── S3 ListObjects (bucket de certificados)
        ├── Parsear fecha expiración de cada cert
        │
        ├── Si días < 35:
        │     ├── Crear ticket Jira (prioridad según días)
        │     ├── Slack #devops-monitoring-certificados
        │     └── SES email → arquitecto responsable
        │
        └── CloudWatch Logs (registro auditoria)
```

### Umbrales de alerta

| Días restantes | Prioridad Jira | Canal |
|---|---|---|
| 35 días | Media | Slack + Jira |
| 15 días | Alta | Slack + Jira + Email |
| 7 días | Crítica | Slack + Jira + Email + SMS |
| Vencido | Bloqueante | Todos los canales |

### Ticket Jira automático generado

```
Título: 🔐 Certificado próximo a vencer: <nombre-cert>
Descripción:
  📋 Certificado: <path en S3>
  📅 Fecha expiración: <fecha>
  ⏰ Días restantes: <N> días
  👤 Responsable: <arquitecto>
  
  Este ticket fue generado automáticamente por
  el sistema de monitoreo de certificados DevOps.

Prioridad: Alta
Etiquetas: certificados, ssl, auto-generated, renovacion
```

---

## 🧠 Evolución 3 — Amazon Bedrock Knowledge Base

### ¿Qué hace?

**Modo dummies:** @Evita tiene una "memoria" donde están guardados todos
los runbooks, procedimientos y soluciones de problemas anteriores.
Cuando alguien pregunta en Slack "¿cómo renuevo un certificado?",
@Evita busca en esa memoria y responde automáticamente.

**Modo senior:** Knowledge Base en Amazon Bedrock con documentación
técnica indexada (runbooks, postmortems, procedimientos). @Evita usa
RAG (Retrieval Augmented Generation) para responder preguntas en
#devops-faqs con contexto específico de la organización, sin alucinar
información genérica de Claude.

### Flujo RAG

```
Usuario en Slack: "@Evita ¿cómo renuevo el cert de producción?"
        │
        ▼
Lambda @Evita → Bedrock Knowledge Base
        │         (busca en documentación indexada)
        │
        ▼
Bedrock Claude (genera respuesta con contexto específico)
        │
        ▼
Slack: respuesta con pasos exactos + link al runbook en Confluence
```

---

## 📊 Evolución 4 — Dashboard Ejecutivo

**Modo dummies:** Un tablero en tiempo real que muestra el estado de
salud de toda la infraestructura en una sola pantalla — como el panel
de control de un avión pero para la arquitectura cloud.

**Modo senior:** CloudWatch Dashboard + Grafana con métricas de negocio:
disponibilidad por servicio, MTTR, certificados activos vs por vencer,
findings de seguridad por severidad, costo por servicio. Alimentado
por datos de GuardDuty, CloudTrail, RDS, Lambda y ElastiCache.

---

## 🗺️ Timeline de Implementación

```
Sprint 1 (Semanas 1-2):
  ✅ Infraestructura base (COMPLETADO)
  ✅ CloudTrail + GuardDuty + Backup + Grafana

Sprint 2 (Semanas 3-4):
  🔲 Lambda @Evita-Processor
  🔲 Integración Slack Webhooks
  🔲 EventBridge rules para GuardDuty

Sprint 3 (Semanas 5-6):
  🔲 Lambda cert-monitor
  🔲 Integración Jira REST API
  🔲 SES para notificaciones email

Sprint 4 (Semanas 7-8):
  🔲 Bedrock Knowledge Base con runbooks
  🔲 RAG en @Evita para #devops-faqs
  🔲 Dashboard ejecutivo
```

---

## 💡 Por qué esto importa

Esta evolución convierte la infraestructura de **reactiva a proactiva**:

| Hoy | Con @Evita |
|---|---|
| GuardDuty alerta → alguien lo ve | GuardDuty alerta → ticket creado automáticamente |
| Cert vence → falla en producción | 35 días antes → ticket + email + Slack |
| Error en Lambda → revisar logs | Error → @Evita analiza con IA y sugiere solución |
| Pregunta en Slack → esperar respuesta | @Evita responde en segundos desde la KB |

---

*Roadmap diseñado por Oscar Diaz — Platform & DevOps Engineer*
*Basado en implementaciones reales en entornos enterprise de alta disponibilidad*
