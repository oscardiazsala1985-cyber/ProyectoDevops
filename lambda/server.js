/**
 * server.js — Versión Express de la app para correr en Docker / EC2
 * El mismo handler de Lambda se reutiliza adaptando el request/response
  */

'use strict';

const express = require('express');
const { handler } = require('./index');

const app = express();
const PORT = process.env.PORT || 8080;

app.use(express.json());

// Health check endpoint — requerido por el ALB Target Group
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    service: 'sre-process-service',
    timestamp: new Date().toISOString(),
    version: process.env.APP_VERSION || '1.0.0'
  });
});

// Endpoint principal — adapta el request HTTP al formato de evento Lambda
app.post('/process', async (req, res) => {
  // Construye un evento Lambda-compatible desde el request HTTP
  const lambdaEvent = {
    body: JSON.stringify(req.body),
    queryStringParameters: req.query,
    isBase64Encoded: false,
    headers: req.headers
  };

  try {
    const result = await handler(lambdaEvent);
    const body = JSON.parse(result.body);

    // Propaga los headers de la respuesta Lambda (incluye X-Cache)
    Object.entries(result.headers || {}).forEach(([key, value]) => {
      res.setHeader(key, value);
    });

    res.status(result.statusCode).json(body);
  } catch (err) {
    console.error('Server error:', err);
    res.status(500).json({ message: 'Internal server error', detail: err.message });
  }
});

// Arrancar el servidor
app.listen(PORT, '0.0.0.0', () => {
  console.log(`✅ SRE Process Service running on port ${PORT}`);
  console.log(`   Health check: http://localhost:${PORT}/health`);
  console.log(`   Process endpoint: POST http://localhost:${PORT}/process`);
});

module.exports = app;
