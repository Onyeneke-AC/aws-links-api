import client from 'prom-client';

// One registry per app instance, so tests don't share global state.
export function createMetrics() {
  const registry = new client.Registry();
  client.collectDefaultMetrics({ register: registry }); // CPU, memory, event-loop lag, GC

  const httpDuration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds',
    // `route` is the route *template* (e.g. "/:code"), never the raw URL,
    // so label cardinality stays bounded.
    labelNames: ['method', 'route', 'status_code'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [registry],
  });

  return { registry, httpDuration };
}
