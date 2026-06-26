/**
 * index.test.js — Pruebas unitarias e integración del handler Lambda
 * Punto 11 del reto: pruebas automatizadas
  * antes de que llegue al servidor de producción
 */

'use strict';

// Mock de AWS SDK S3 — no hacemos llamadas reales en los tests
jest.mock('@aws-sdk/client-s3', () => ({
  S3Client: jest.fn().mockImplementation(() => ({
    send: jest.fn().mockResolvedValue({ ETag: '"mock-etag"' })
  })),
  PutObjectCommand: jest.fn()
}));

// Mock de conexión Redis — simulamos respuestas sin Redis real
const mockRedisData = {};
jest.mock('net', () => {
  const EventEmitter = require('events');
  return {
    createConnection: jest.fn().mockImplementation((opts) => {
      const socket = new EventEmitter();
      socket.write = jest.fn((command) => {
        // Simula respuestas Redis según el comando
        setTimeout(() => {
          if (command.includes('GET')) {
            const key = command.split('\r\n')[4];
            const value = mockRedisData[key] || null;
            if (value) {
              socket.emit('data', `$${Buffer.byteLength(value)}\r\n${value}\r\n`);
            } else {
              socket.emit('data', '$-1\r\n');
            }
          } else if (command.includes('SETEX')) {
            const parts = command.split('\r\n');
            const key = parts[4];
            const value = parts[8];
            mockRedisData[key] = value;
            socket.emit('data', '+OK\r\n');
          }
          socket.emit('end');
        }, 10);
      });
      socket.end = jest.fn();
      socket.destroy = jest.fn();
      return socket;
    })
  };
});

// Variables de entorno para los tests
process.env.REDIS_HOST = 'localhost';
process.env.REDIS_PORT = '6379';
process.env.REDIS_TTL_SECONDS = '60';
process.env.BUCKET_NAME = 'test-bucket';

const { handler } = require('./index');

// ============================================================
// PRUEBAS UNITARIAS — funciones internas
// ============================================================

describe('Unit Tests — Procesamiento de payload', () => {
  test('debe retornar statusCode 200 con un payload válido', async () => {
    const event = {
      body: JSON.stringify({ data: 'test-lite-thinking' }),
      queryStringParameters: {},
      isBase64Encoded: false
    };

    const result = await handler(event);

    expect(result.statusCode).toBe(200);
    expect(result.headers['Content-Type']).toBe('application/json');
    expect(result.headers['X-Cache']).toBeDefined();
  });

  test('debe incluir id, processedAt y algorithm en la respuesta', async () => {
    const event = {
      body: JSON.stringify({ data: 'unique-payload-123' }),
      queryStringParameters: {},
      isBase64Encoded: false
    };

    const result = await handler(event);
    const body = JSON.parse(result.body);

    expect(body.id).toBeDefined();
    expect(body.processedAt).toBeDefined();
    expect(body.algorithm).toBe('sha256');
    expect(body.result).toBeDefined();
  });

  test('debe responder X-Cache: MISS en la primera petición', async () => {
    const event = {
      body: JSON.stringify({ data: 'fresh-payload-never-seen' }),
      queryStringParameters: {},
      isBase64Encoded: false
    };

    const result = await handler(event);

    expect(result.headers['X-Cache']).toBe('MISS');
  });

  test('debe manejar body vacío sin crashear', async () => {
    const event = {
      body: '',
      queryStringParameters: {},
      isBase64Encoded: false
    };

    const result = await handler(event);

    expect(result.statusCode).toBe(200);
  });

  test('debe manejar body base64 correctamente', async () => {
    const originalBody = JSON.stringify({ data: 'base64-test' });
    const event = {
      body: Buffer.from(originalBody).toString('base64'),
      queryStringParameters: {},
      isBase64Encoded: true
    };

    const result = await handler(event);

    expect(result.statusCode).toBe(200);
  });
});

// ============================================================
// PRUEBAS DE INTEGRACIÓN — flujo completo cache MISS → HIT
// ============================================================

describe('Integration Tests — Cache flow', () => {
  beforeEach(() => {
    // Limpia el mock de Redis entre pruebas
    Object.keys(mockRedisData).forEach(k => delete mockRedisData[k]);
  });

  test('flujo completo: primera llamada MISS, segunda llamada HIT', async () => {
    const event = {
      body: JSON.stringify({ data: 'cache-flow-test' }),
      queryStringParameters: {},
      isBase64Encoded: false
    };

    // Primera llamada — debe ser MISS (no está en caché)
    const firstResult = await handler(event);
    expect(firstResult.headers['X-Cache']).toBe('MISS');

    // Segunda llamada con el mismo payload — debe ser HIT (está en caché)
    const secondResult = await handler(event);
    expect(secondResult.headers['X-Cache']).toBe('HIT');
  });

  test('dos payloads diferentes deben generar ids distintos', async () => {
    const event1 = {
      body: JSON.stringify({ data: 'payload-A' }),
      queryStringParameters: {},
      isBase64Encoded: false
    };
    const event2 = {
      body: JSON.stringify({ data: 'payload-B' }),
      queryStringParameters: {},
      isBase64Encoded: false
    };

    const result1 = await handler(event1);
    const result2 = await handler(event2);

    const body1 = JSON.parse(result1.body);
    const body2 = JSON.parse(result2.body);

    expect(body1.id).not.toBe(body2.id);
  });
});
