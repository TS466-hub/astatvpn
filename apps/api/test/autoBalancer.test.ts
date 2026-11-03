import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { withAutoConfig } from '../src/services/autoBalancer.js';

const host = (name: string, address: string) => ({
  remarks: name,
  dns: { servers: ['1.1.1.1'] },
  routing: { domainStrategy: 'IPIfNonMatch', rules: [{ type: 'field', domain: ['domain:ru'], outboundTag: 'direct' }] },
  inbounds: [{ tag: 'socks', port: 10808, protocol: 'socks' }],
  outbounds: [{ tag: 'proxy', protocol: 'vless', settings: { vnext: [{ address }] } }, { tag: 'direct', protocol: 'freedom' }, { tag: 'block', protocol: 'blackhole' }],
});

describe('конфигурация «⚡ Авто»', () => {
  it('идёт первой, содержит все серверы, балансировщик и наблюдение за задержкой', () => {
    const out = withAutoConfig([host('🇫🇮 Finland', '1.1.1.1'), host('🇳🇱 Netherlands', '2.2.2.2')])!;
    expect(out.map((c) => c.remarks)).toEqual(['🇪🇺 Авто', '🇫🇮 Finland', '🇳🇱 Netherlands']);
    const auto = out[0] as any;
    expect(auto.outbounds.map((o: any) => o.tag)).toEqual(['proxy-0', 'proxy-1', 'direct', 'block']);
    expect(auto.outbounds[1].settings.vnext[0].address).toBe('2.2.2.2');
    expect(auto.routing.balancers[0]).toMatchObject({ tag: 'auto', selector: ['proxy-'], strategy: { type: 'leastPing' }, fallbackTag: 'proxy-0' });
    expect(auto.observatory.subjectSelector).toEqual(['proxy-']);
    // российские сайты по-прежнему напрямую, а последнее правило отправляет остальное в балансировщик
    expect(auto.routing.rules[0]).toMatchObject({ outboundTag: 'direct' });
    expect(auto.routing.rules.at(-1)).toMatchObject({ balancerTag: 'auto' });
    expect(auto.inbounds).toEqual(host('x', 'x').inbounds);
  });
  it('исключённые серверы остаются в списке, но не участвуют в автовыборе', () => {
    const out = withAutoConfig([host('🇫🇮 Finland', '1.1.1.1'), host('🇳🇱 Netherlands', '2.2.2.2'), host('🇵🇱 Poland', '3.3.3.3')], [' 1.1.1.1', ''])!;
    expect(out.map((c) => c.remarks)).toEqual(['🇪🇺 Авто', '🇫🇮 Finland', '🇳🇱 Netherlands', '🇵🇱 Poland']);
    expect((out[0] as any).outbounds.filter((o: any) => o.protocol === 'vless').map((o: any) => o.settings.vnext[0].address)).toEqual(['2.2.2.2', '3.3.3.3']);
    const byName = withAutoConfig([host('🇫🇮 Finland', '1.1.1.1'), host('B', '2.2.2.2')], ['🇫🇮 finland'])!;
    expect((byName[0] as any).outbounds[0].settings.vnext[0].address).toBe('2.2.2.2');
    const all = withAutoConfig([host('A', '1.1.1.1'), host('B', '2.2.2.2')], ['1.1.1.1', '2.2.2.2'])!;
    expect((all[0] as any).routing.balancers[0].selector).toEqual(['proxy-']);
    expect((all[0] as any).outbounds.filter((o: any) => o.protocol === 'vless')).toHaveLength(2);
  });
  it('исходные конфигурации не меняются', () => {
    const src = [host('A', '1.1.1.1'), host('B', '2.2.2.2')];
    const copy = structuredClone(src);
    withAutoConfig(src);
    expect(src).toEqual(copy);
  });
  it('один сервер, чужой формат или повторный вызов: без изменений', () => {
    expect(withAutoConfig([host('A', '1.1.1.1')])).toBeNull();
    expect(withAutoConfig({ outbounds: [] })).toBeNull();
    expect(withAutoConfig([host('A', '1.1.1.1'), { remarks: 'B', outbounds: [] }])).toBeNull();
    const once = withAutoConfig([host('A', '1.1.1.1'), host('B', '2.2.2.2')])!;
    expect(withAutoConfig(once)).toHaveLength(3);
  });
});

describe('прослойка подписки', () => {
  let upstream: Server;
  let app: Awaited<ReturnType<typeof buildApp>>;
  let seen: Record<string, string | string[] | undefined> = {};
  let mode: 'json' | 'text' | 'error' = 'json';
  beforeAll(async () => {
    upstream = createServer((req, res) => {
      seen = req.headers;
      if (mode === 'error') { res.writeHead(404); return res.end('nope'); }
      res.setHeader('profile-title', 'base64:QXN0YXRWUE4=');
      res.setHeader('subscription-userinfo', 'upload=0; download=0; total=0; expire=0');
      if (mode === 'text') { res.setHeader('content-type', 'text/plain'); return res.end('dmxlc3M6Ly8='); }
      res.setHeader('content-type', 'application/json; charset=utf-8');
      res.end(JSON.stringify([host('A', '1.1.1.1'), host('B', '2.2.2.2')]));
    });
    await new Promise<void>((r) => upstream.listen(0, '127.0.0.1', r));
    process.env.SUBSCRIPTION_PAGE_URL = `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`;
    app = await buildApp({ logger: false });
  });
  afterAll(async () => { delete process.env.SUBSCRIPTION_PAGE_URL; await app.close(); upstream.close(); });

  it('добавляет «⚡ Авто», сохраняет заголовки подписки и передаёт данные устройства панели', async () => {
    mode = 'json';
    const r = await app.inject({ method: 'GET', url: '/sub-auto/AbCdEf123456', headers: { 'user-agent': 'Happ/3.2', 'x-hwid': 'device-1' }, remoteAddress: '5.6.7.8' });
    expect(r.statusCode).toBe(200);
    expect(r.json().map((c: any) => c.remarks)).toEqual(['🇪🇺 Авто', 'A', 'B']);
    expect(r.headers['profile-title']).toBe('base64:QXN0YXRWUE4=');
    expect(r.headers['subscription-userinfo']).toContain('expire=0');
    expect(seen['user-agent']).toBe('Happ/3.2');
    expect(seen['x-hwid']).toBe('device-1');
    expect(seen['x-forwarded-proto']).toBe('https');
    expect(seen['x-forwarded-for']).toBe('5.6.7.8');
  });
  it('другие форматы и ошибки отдаёт без изменений', async () => {
    mode = 'text';
    let r = await app.inject({ method: 'GET', url: '/sub-auto/AbCdEf123456' });
    expect(r.body).toBe('dmxlc3M6Ly8=');
    mode = 'error';
    r = await app.inject({ method: 'GET', url: '/sub-auto/AbCdEf123456' });
    expect(r.statusCode).toBe(404);
  });
  it('не пропускает к панели посторонние пути', async () => {
    expect((await app.inject({ method: 'GET', url: '/sub-auto/..%2Fapi%2Fusers' })).statusCode).toBe(404);
    expect((await app.inject({ method: 'GET', url: '/sub-auto/abc/def/ghi' })).statusCode).toBe(404);
  });
});
