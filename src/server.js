import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { migrate } from './db.js';

const SHUTDOWN_TIMEOUT_MS = 10_000; // ECS stopTimeout defaults to 30s

const config = loadConfig(); // throws (exit 1) on bad config: fail fast at boot
const app = buildApp({ config });

// Fail fast: if we can't reach or migrate the DB at boot, exit non-zero so ECS
// replaces the task and the deployment circuit breaker can count the failure.
// The log line says why (e.g. "password authentication failed").
try {
  await migrate(app.db);
  await app.listen({ port: config.port, host: config.host });
} catch (err) {
  app.log.fatal({ err }, 'startup failed');
  await app.close().catch(() => {});
  process.exit(1);
}

// ECS sends SIGTERM on stop. By then the ALB has already drained the task.
// app.close() stops accepting connections, waits for in-flight requests, then
// runs onClose hooks (closes the DB pool). The timer is a safety net.
let shuttingDown = false;
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ signal }, 'shutting down');
    setTimeout(() => {
      app.log.error('graceful shutdown timed out, forcing exit');
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS).unref();
    try {
      await app.close();
      process.exit(0);
    } catch (err) {
      app.log.error({ err }, 'error during shutdown');
      process.exit(1);
    }
  });
}
