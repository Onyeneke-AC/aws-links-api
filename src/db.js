import pg from 'pg';

export function createPool(dbConfig, logger) {
  const pool = new pg.Pool({
    max: dbConfig.poolMax,
    connectionTimeoutMillis: dbConfig.connectTimeoutMs,
    statement_timeout: dbConfig.statementTimeoutMs,
    idleTimeoutMillis: 30_000,
    application_name: 'links-api',
  });

  // An idle client can error out (DB restart, failover, network blip).
  // Without this listener the 'error' event would crash the process.
  pool.on('error', (err) => {
    logger.error({ err }, 'idle postgres client error');
  });

  return pool;
}

// Arbitrary constant: all app instances take the same advisory lock.
const MIGRATION_LOCK_ID = 7_242_001;

// Idempotent schema setup, run on every boot. The advisory lock stops two
// tasks starting together from racing on CREATE TABLE.
export async function migrate(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock($1)', [MIGRATION_LOCK_ID]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS links (
        code        varchar(16) PRIMARY KEY,
        target_url  text        NOT NULL,
        created_at  timestamptz NOT NULL DEFAULT now()
      )
    `);
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

// Returns true if inserted, false if the code already exists.
export async function insertLink(pool, code, targetUrl) {
  const { rowCount } = await pool.query(
    'INSERT INTO links (code, target_url) VALUES ($1, $2) ON CONFLICT (code) DO NOTHING',
    [code, targetUrl],
  );
  return rowCount === 1;
}

export async function findLink(pool, code) {
  const { rows } = await pool.query('SELECT target_url FROM links WHERE code = $1', [code]);
  return rows[0]?.target_url ?? null;
}

export async function ping(pool) {
  await pool.query('SELECT 1');
}
