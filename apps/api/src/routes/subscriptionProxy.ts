import type { FastifyInstance } from 'fastify';
import { withAutoConfig } from '../services/autoBalancer.js';
import { getSettings } from '../services/settings.js';

const UPSTREAM = () => (process.env.SUBSCRIPTION_PAGE_URL ?? 'http://remnawave-subscription-page:3010').replace(/\/$/, '');
const HOP = new Set(['host', 'connection', 'content-length', 'accept-encoding', 'keep-alive', 'transfer-encoding', 'upgrade']);

/**
 * Прослойка перед страницей подписок для приложений на Xray JSON (Caddy направляет сюда только их).
 * Ответ панели не меняется, кроме добавленного первым пунктом «⚡ Авто». При любом сбое отдаём ответ панели как есть.
 */
export async function subscriptionProxyRoutes(app: FastifyInstance) {
  app.get('/sub-auto/*', { config: { rateLimit: { max: 60, timeWindow: '1 minute' } } }, async (req, reply) => {
    const path = (req.params as { '*': string })['*'];
    if (!/^[A-Za-z0-9_-]{6,64}(\/[a-z0-9-]{1,20})?$/.test(path)) return reply.code(404).send();
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries(req.headers)) if (!HOP.has(k) && typeof v === 'string') headers[k] = v;
    headers['x-forwarded-proto'] = 'https';
    headers['x-forwarded-for'] = req.ip;
    const res = await fetch(`${UPSTREAM()}/${path}`, { headers, signal: AbortSignal.timeout(15_000) });
    const text = await res.text();
    for (const [k, v] of res.headers) if (!HOP.has(k) && k !== 'content-encoding') reply.header(k, v);
    reply.code(res.status);
    if (res.ok && (res.headers.get('content-type') ?? '').includes('json')) {
      try {
        const exclude = (await getSettings('monitoring')).auto_exclude.split(',');
        const auto = withAutoConfig(JSON.parse(text), exclude);
        if (auto) return reply.send(JSON.stringify(auto));
      } catch {
        /* не JSON: отдаём как есть */
      }
    }
    return reply.send(text);
  });
}
