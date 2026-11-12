// All configuration comes from environment variables (12-factor).
// Database settings are NOT read here: node-postgres reads the standard
// libpq variables (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD, PGSSLMODE)
// itself, so the password is never handled by our code.

const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'];

function int(env, name, fallback, { min, max }) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}, got "${raw}"`);
  }
  return value;
}

export function loadConfig(env = process.env) {
  const logLevel = env.LOG_LEVEL || 'info';
  if (!LOG_LEVELS.includes(logLevel)) {
    throw new Error(`LOG_LEVEL must be one of ${LOG_LEVELS.join(', ')}, got "${logLevel}"`);
  }

  // Optional: if set, POST /links also returns a full short URL.
  let publicBaseUrl = null;
  if (env.PUBLIC_BASE_URL) {
    publicBaseUrl = new URL(env.PUBLIC_BASE_URL).origin; // throws on garbage
  }

  return {
    port: int(env, 'PORT', 3000, { min: 1, max: 65535 }),
    host: env.HOST || '0.0.0.0',
    logLevel,
    publicBaseUrl,
    db: {
      poolMax: int(env, 'DB_POOL_MAX', 10, { min: 1, max: 100 }),
      // Keep both well under the ALB health-check timeout (5s) so /readyz
      // answers "not ready" instead of hanging.
      connectTimeoutMs: int(env, 'DB_CONNECT_TIMEOUT_MS', 2000, { min: 100, max: 30000 }),
      statementTimeoutMs: int(env, 'DB_STATEMENT_TIMEOUT_MS', 2000, { min: 100, max: 60000 }),
    },
  };
}
