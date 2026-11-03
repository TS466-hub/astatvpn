import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { closeDb, sql } from '../src/db/index.js';
import { migrate } from '../src/db/migrate.js';
import { signAdminToken } from '../src/lib/jwt.js';
import { normalizePhone } from '../src/services/phoneAuth.js';
import { clearSettingsCache, setSettings } from '../src/services/settings.js';

let app: Awaited<ReturnType<typeof buildApp>>;
let mock: Server;
let calls: { path: string; auth?: string; body: any }[] = [];
let failWith: { code: number; error: string } | null = null;

const post = (url: string, payload: unknown, ip = '10.0.0.1') => app.inject({ method: 'POST', url: `/api/v1${url}`, payload: payload as object, remoteAddress: ip });
const lastCode = () => String(calls.at(-1)!.body.code);
const PHONE = '+7 (900) 123-45-67';
const PASSWORD = 'correct-horse-1';

const enable = (patch: Record<string, unknown> = {}) => setSettings('phone_auth', { enabled: true, service_id: '42', key: 'secret-key', cooldown_sec: 15, ...patch });
/** Пауза между звонками не даёт повторить запрос сразу: сдвигаем прошлые записи в прошлое. */
const age = () => sql()`update phone_verifications set created_at = created_at - interval '1 hour'`;
async function register(phone = PHONE, password = PASSWORD) {
  const start = await post('/auth/phone/start', { phone, purpose: 'register' });
  expect(start.statusCode).toBe(200);
  return post('/auth/phone/register', { id: start.json().id, code: lastCode(), password });
}

beforeAll(async () => {
  mock = createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      calls.push({ path: req.url ?? '', auth: req.headers.authorization, body: raw ? JSON.parse(raw) : null });
      res.setHeader('content-type', 'application/json');
      if (failWith) return res.end(JSON.stringify({ status: false, ...failWith }));
      if (req.url?.startsWith('/getBalance')) return res.end(JSON.stringify({ status: true, rub_balance: 84.6, tariff_name: 'Единый' }));
      res.end(JSON.stringify({ status: true, ucaller_id: 777, code: JSON.parse(raw).code }));
    });
  });
  await new Promise<void>((r) => mock.listen(0, '127.0.0.1', r));
  process.env.UCALLER_API_URL = `http://127.0.0.1:${(mock.address() as AddressInfo).port}`;
  await sql()`drop schema public cascade`;
  await sql()`create schema public`;
  await migrate();
  app = await buildApp({ logger: false });
});
beforeEach(async () => {
  calls = [];
  failWith = null;
  await sql()`truncate users, admins, settings, phone_verifications cascade`;
  clearSettingsCache();
  await enable();
});
afterAll(async () => {
  delete process.env.UCALLER_API_URL;
  await app.close();
  await closeDb();
  mock.close();
});

describe('нормализация номера', () => {
  it('приводит российские форматы и отклоняет короткие', () => {
    expect(normalizePhone('+7 (900) 123-45-67')).toBe('79001234567');
    expect(normalizePhone('89001234567')).toBe('79001234567');
    expect(normalizePhone('9001234567')).toBe('79001234567');
    expect(normalizePhone('+49 151 1234 5678')).toBe('4915112345678');
    expect(() => normalizePhone('12345')).toThrow();
  });
});

describe('регистрация по номеру', () => {
  it('создаёт аккаунт без Telegram, пароль хранится только в виде хэша', async () => {
    const r = await register();
    expect(r.statusCode).toBe(200);
    const me = await app.inject({ method: 'GET', url: '/api/v1/me', headers: { authorization: `Bearer ${r.json().accessToken}` } });
    expect(me.statusCode).toBe(200);
    expect(me.json().tgId).toBeNull();
    const [u] = await sql()`select phone, tg_id, password_hash from users`;
    expect(u!.phone).toBe('79001234567');
    expect(u!.password_hash).toMatch(/^scrypt\$/);
    expect(u!.password_hash).not.toContain(PASSWORD);
    expect(calls.at(-1)!.auth).toBe('Bearer secret-key.42');
    expect(calls.at(-1)!.body.phone).toBe(79001234567);
  });

  it('код хранится хэшем и одноразовый', async () => {
    const start = await post('/auth/phone/start', { phone: PHONE, purpose: 'register' });
    const code = lastCode();
    const [v] = await sql()`select code_hash from phone_verifications`;
    expect(v!.code_hash).not.toContain(code);
    expect((await post('/auth/phone/register', { id: start.json().id, code, password: PASSWORD })).statusCode).toBe(200);
    expect((await post('/auth/phone/register', { id: start.json().id, code, password: PASSWORD })).statusCode).toBe(400);
  });

  it('после пяти неверных кодов верный тоже не принимается', async () => {
    const start = await post('/auth/phone/start', { phone: PHONE, purpose: 'register' });
    const good = lastCode();
    const bad = good === '1111' ? '2222' : '1111';
    for (let i = 0; i < 5; i++) expect((await post('/auth/phone/register', { id: start.json().id, code: bad, password: PASSWORD })).statusCode).toBe(400);
    const r = await post('/auth/phone/register', { id: start.json().id, code: good, password: PASSWORD });
    expect(r.statusCode).toBe(400);
    expect(await sql()`select 1 from users`).toHaveLength(0);
  });

  it('занятый номер: без подтверждения звонком не видно, что он занят, и второго аккаунта нет', async () => {
    await register();
    await age();
    const start = await post('/auth/phone/start', { phone: PHONE, purpose: 'register' });
    expect(start.statusCode).toBe(200);
    const r = await post('/auth/phone/register', { id: start.json().id, code: lastCode(), password: 'another-pass-2' });
    expect(r.statusCode).toBe(409);
    expect(await sql()`select 1 from users`).toHaveLength(1);
  });

  it('отключённая настройка блокирует звонок', async () => {
    await setSettings('phone_auth', { enabled: false });
    expect((await post('/auth/phone/start', { phone: PHONE, purpose: 'register' })).statusCode).toBe(403);
    expect(calls).toHaveLength(0);
  });

  it('ошибка uCaller не показывает пользователю подробности', async () => {
    failWith = { code: 1002, error: 'Недостаточно средств на балансе secret' };
    const r = await post('/auth/phone/start', { phone: PHONE, purpose: 'register' });
    expect(r.statusCode).toBe(502);
    expect(r.body).not.toContain('secret');
  });
});

describe('лимиты защищают баланс', () => {
  it('пауза между звонками на номер', async () => {
    expect((await post('/auth/phone/start', { phone: PHONE, purpose: 'register' })).statusCode).toBe(200);
    expect((await post('/auth/phone/start', { phone: PHONE, purpose: 'register' })).statusCode).toBe(429);
    expect(calls).toHaveLength(1);
  });
  it('лимит на номер в сутки', async () => {
    await enable({ max_per_phone_day: 2 });
    for (let i = 0; i < 2; i++) { expect((await post('/auth/phone/start', { phone: PHONE, purpose: 'register' }, `10.1.0.${i}`)).statusCode).toBe(200); await age(); }
    expect((await post('/auth/phone/start', { phone: PHONE, purpose: 'register' }, '10.1.0.9')).statusCode).toBe(429);
    expect(calls).toHaveLength(2);
  });
  it('лимит на IP в сутки', async () => {
    await enable({ max_per_ip_day: 2 });
    expect((await post('/auth/phone/start', { phone: '79001000001', purpose: 'register' }, '10.2.0.1')).statusCode).toBe(200);
    expect((await post('/auth/phone/start', { phone: '79001000002', purpose: 'register' }, '10.2.0.1')).statusCode).toBe(200);
    expect((await post('/auth/phone/start', { phone: '79001000003', purpose: 'register' }, '10.2.0.1')).statusCode).toBe(429);
  });
  it('общий суточный лимит, параллельные запросы его не обходят', async () => {
    await enable({ max_per_day: 3 });
    const rs = await Promise.all(Array.from({ length: 6 }, (_, i) => post('/auth/phone/start', { phone: `7900200000${i}`, purpose: 'register' }, `10.3.0.${i}`)));
    expect(rs.filter((r) => r.statusCode === 200)).toHaveLength(3);
    expect(calls).toHaveLength(3);
  });
});

describe('вход и сброс пароля', () => {
  it('вход по паролю без звонка, неверный пароль и чужой номер дают одинаковый ответ', async () => {
    await register();
    const before = calls.length;
    expect((await post('/auth/phone/login', { phone: '89001234567', password: PASSWORD })).statusCode).toBe(200);
    const wrong = await post('/auth/phone/login', { phone: PHONE, password: 'wrong-password' });
    const unknown = await post('/auth/phone/login', { phone: '79009999999', password: 'wrong-password' });
    expect(wrong.statusCode).toBe(400);
    expect(unknown.statusCode).toBe(wrong.statusCode);
    expect(unknown.body).toBe(wrong.body);
    expect(calls).toHaveLength(before);
  });

  it('десять ошибок подряд временно блокируют вход', async () => {
    await register();
    for (let i = 0; i < 10; i++) await post('/auth/phone/login', { phone: PHONE, password: 'wrong-password' }, `10.4.0.${i}`);
    expect((await post('/auth/phone/login', { phone: PHONE, password: PASSWORD }, '10.4.1.1')).statusCode).toBe(429);
  });

  it('сброс меняет пароль и завершает старые сессии', async () => {
    const old = (await register()).json().accessToken;
    await age();
    await sql()`update users set password_changed_at = null`;
    const start = await post('/auth/phone/start', { phone: PHONE, purpose: 'reset' });
    await new Promise((r) => setTimeout(r, 1100));
    const r = await post('/auth/phone/reset', { id: start.json().id, code: lastCode(), password: 'brand-new-pass-3' });
    expect(r.statusCode).toBe(200);
    expect((await post('/auth/phone/login', { phone: PHONE, password: PASSWORD })).statusCode).toBe(400);
    expect((await post('/auth/phone/login', { phone: PHONE, password: 'brand-new-pass-3' })).statusCode).toBe(200);
    expect((await app.inject({ method: 'GET', url: '/api/v1/me', headers: { authorization: `Bearer ${old}` } })).statusCode).toBe(401);
    expect((await app.inject({ method: 'GET', url: '/api/v1/me', headers: { authorization: `Bearer ${r.json().accessToken}` } })).statusCode).toBe(200);
  });

  it('сброс для незнакомого номера: ответ тот же, звонка нет', async () => {
    const r = await post('/auth/phone/start', { phone: '79008888888', purpose: 'reset' });
    expect(r.statusCode).toBe(200);
    expect(calls).toHaveLength(0);
    expect((await post('/auth/phone/reset', { id: r.json().id, code: '1234', password: 'brand-new-pass-3' })).statusCode).toBe(400);
  });
});

describe('админка', () => {
  it('ключ скрыт в настройках, проверка показывает баланс, хэш пароля не отдаётся', async () => {
    const [a] = await sql()`insert into admins (email, password_hash, role) values ('o@example.test', 'x', 'owner') returning id`;
    const headers = { authorization: `Bearer ${await signAdminToken(a!.id, 'owner', { epoch: 0 })}` };
    const settings = await app.inject({ method: 'GET', url: '/api/v1/admin/settings', headers });
    expect(settings.statusCode).toBe(200);
    expect(settings.body).not.toContain('secret-key');
    const test = await app.inject({ method: 'POST', url: '/api/v1/admin/settings/test/ucaller', headers });
    expect(test.json()).toMatchObject({ ok: true, balance: 84.6 });
    await register();
    const [u] = await sql()`select id from users`;
    const card = await app.inject({ method: 'GET', url: `/api/v1/admin/users/${u!.id}`, headers });
    expect(card.statusCode).toBe(200);
    expect(card.json().user.phone).toBe('79001234567');
    expect(card.body).not.toContain('scrypt$');
    expect(card.json().user.password_hash).toBeUndefined();
  });
});
