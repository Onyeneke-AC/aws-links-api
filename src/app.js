import { STATUS_CODES } from 'node:http';
import Fastify, { LogController } from 'fastify';
import { createPool, findLink, insertLink, ping } from './db.js';
import { CODE_PATTERN, MAX_URL_LENGTH, generateCode, normaliseTargetUrl } from './links.js';
import { createMetrics } from './metrics.js';

const MAX_CODE_ATTEMPTS = 5;

// Routes that are hit constantly by ALB/ECS/scrapers: no access log line.
const QUIET = { config: { accessLog: false } };

export function buildApp({ config, pool } = {}) {
  const app = Fastify({
    logger: {
      level: config.logLevel,
      timestamp: () => `,"time":"${new Date().toISOString()}"`,
    },
    // ALB sets X-Amzn-Trace-Id on every request; using it as our request id
    // lets us join app logs with ALB access logs.
    requestIdHeader: 'x-amzn-trace-id',
    // Turn off Fastify's two-lines-per-request logging; we write one
    // access-log line ourselves in onResponse.
    logController: new LogController({ disableRequestLogging: true }),
    bodyLimit: 16 * 1024,
  });

  const ownsPool = !pool;
  const db = pool ?? createPool(config.db, app.log);
  const metrics = createMetrics();

  app.addHook('onResponse', async (request, reply) => {
    const route = request.routeOptions.url ?? 'unmatched';
    const seconds = reply.elapsedTime / 1000;
    metrics.httpDuration
      .labels(request.method, route, String(reply.statusCode))
      .observe(seconds);

    if (request.routeOptions.config?.accessLog === false) return;
    // Log the route and status, never the target URL (it may carry tokens).
    request.log.info(
      {
        method: request.method,
        route,
        statusCode: reply.statusCode,
        durationMs: Math.round(reply.elapsedTime),
      },
      'request completed',
    );
  });

  // Never leak internal error messages (e.g. DB errors) to clients.
  app.setErrorHandler((err, request, reply) => {
    const status = err.statusCode && err.statusCode >= 400 ? err.statusCode : 500;
    if (status >= 500) {
      request.log.error({ err }, 'request failed');
      return reply.code(500).send({ statusCode: 500, error: 'Internal Server Error' });
    }
    // 4xx (validation, bad JSON, body too large): safe and useful to show.
    return reply
      .code(status)
      .send({ statusCode: status, error: STATUS_CODES[status], message: err.message });
  });

  app.get('/healthz', QUIET, async () => ({ status: 'ok' }));

  app.get('/readyz', QUIET, async (request, reply) => {
    try {
      await ping(db);
      return { status: 'ready' };
    } catch (err) {
      request.log.warn({ err }, 'readiness check failed: database unreachable');
      return reply.code(503).send({ status: 'not ready' });
    }
  });

  app.get('/metrics', QUIET, async (_request, reply) => {
    reply.type(metrics.registry.contentType);
    return metrics.registry.metrics();
  });

  app.post(
    '/links',
    {
      schema: {
        body: {
          type: 'object',
          required: ['url'],
          properties: { url: { type: 'string', minLength: 1, maxLength: MAX_URL_LENGTH } },
        },
      },
    },
    async (request, reply) => {
      const target = normaliseTargetUrl(request.body.url);
      if (!target) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'Bad Request',
          message: 'url must be an absolute http or https URL',
        });
      }

      // A collision is ~1 in trillions, but handle it rather than assume it.
      for (let attempt = 1; attempt <= MAX_CODE_ATTEMPTS; attempt++) {
        const code = generateCode();
        if (await insertLink(db, code, target)) {
          request.log.info({ code }, 'link created');
          const body = { code, target_url: target };
          if (config.publicBaseUrl) body.short_url = `${config.publicBaseUrl}/${code}`;
          return reply.code(201).send(body);
        }
        request.log.warn({ attempt }, 'short code collision, retrying');
      }
      throw new Error('could not allocate a unique short code');
    },
  );

  app.get('/:code', async (request, reply) => {
    const { code } = request.params;
    // Reject malformed codes without touching the database.
    const target = CODE_PATTERN.test(code) ? await findLink(db, code) : null;
    if (!target) {
      return reply.code(404).send({ statusCode: 404, error: 'Not Found', message: 'link not found' });
    }
    // 302, not 301: browsers cache 301s forever, so a link could never be
    // changed or removed and we'd stop seeing the traffic.
    reply.header('cache-control', 'no-store');
    return reply.redirect(target, 302);
  });

  if (ownsPool) {
    app.addHook('onClose', async () => {
      await db.end();
    });
  }

  app.decorate('db', db);
  return app;
}
