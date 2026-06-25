const crypto = require('crypto');
const net = require('net');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');

const s3 = new S3Client({});
const REDIS_HOST = process.env.REDIS_HOST;
const REDIS_PORT = Number(process.env.REDIS_PORT || 6379);
const REDIS_TTL_SECONDS = Number(process.env.REDIS_TTL_SECONDS || 60);
const BUCKET_NAME = process.env.BUCKET_NAME;

function stableRequestPayload(event) {
  let body = event.body || '';
  if (event.isBase64Encoded && body) body = Buffer.from(body, 'base64').toString('utf8');
  return JSON.stringify({ body, queryStringParameters: event.queryStringParameters || {} });
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function processPayload(payload) {
  return {
    id: sha256(payload),
    processedAt: new Date().toISOString(),
    algorithm: 'sha256',
    result: sha256(`processed:${payload}`)
  };
}

function encodeCommand(parts) {
  return `*${parts.length}\r\n` + parts.map((part) => {
    const value = String(part);
    return `$${Buffer.byteLength(value)}\r\n${value}\r\n`;
  }).join('');
}

function parseBulkString(response) {
  if (response.startsWith('$-1')) return null;
  if (!response.startsWith('$')) throw new Error(`Unexpected Redis response: ${response}`);
  const firstLineEnd = response.indexOf('\r\n');
  const length = Number(response.slice(1, firstLineEnd));
  return response.slice(firstLineEnd + 2, firstLineEnd + 2 + length);
}

function redisCommand(parts) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: REDIS_HOST, port: REDIS_PORT, timeout: 3000 });
    let data = '';

    socket.on('connect', () => socket.write(encodeCommand(parts)));
    socket.on('data', (chunk) => {
      data += chunk.toString('utf8');
      socket.end();
    });
    socket.on('end', () => resolve(data));
    socket.on('timeout', () => {
      socket.destroy();
      reject(new Error('Redis connection timeout'));
    });
    socket.on('error', reject);
  });
}

async function redisGet(key) {
  const response = await redisCommand(['GET', key]);
  return parseBulkString(response);
}

async function redisSetEx(key, ttlSeconds, value) {
  const response = await redisCommand(['SETEX', key, ttlSeconds, value]);
  if (!response.startsWith('+OK')) throw new Error(`Redis SETEX failed: ${response}`);
}

function response(statusCode, cacheStatus, body) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'X-Cache': cacheStatus
    },
    body: JSON.stringify(body)
  };
}

exports.handler = async (event) => {
  try {
    const payload = stableRequestPayload(event);
    const cacheKey = `process:${sha256(payload)}`;

    const cached = await redisGet(cacheKey);
    if (cached) {
      return response(200, 'HIT', JSON.parse(cached));
    }

    const processed = processPayload(payload);
    const today = new Date().toISOString().slice(0, 10);
    const objectKey = `results/${today}/${processed.id}.json`;
    const result = { ...processed, cacheKey, objectKey };

    await s3.send(new PutObjectCommand({
      Bucket: BUCKET_NAME,
      Key: objectKey,
      Body: JSON.stringify(result, null, 2),
      ContentType: 'application/json'
    }));

    await redisSetEx(cacheKey, REDIS_TTL_SECONDS, JSON.stringify(result));
    return response(200, 'MISS', result);
  } catch (error) {
    console.error('Processing error', error);
    return response(500, 'ERROR', {
      message: 'Internal processing error',
      detail: error.message
    });
  }
};
