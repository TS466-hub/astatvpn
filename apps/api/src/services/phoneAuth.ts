import { createHmac, randomInt } from 'node:crypto';
import { config } from '../config.js';
import { sql } from '../db/index.js';
import type { UserRow } from '../db/types.js';
import { hashPassword, safeEqual, verifyPassword } from '../lib/crypto.js';
import { badRequest, conflict, forbidden, HttpError } from '../lib/errors.js';
import { alertAdminsThrottled } from './alerts.js';
import { assertRegistrationOpen } from './closure.js';
import { getSettings } from './settings.js';
import { ucaller } from './ucaller.js';
import { createPhoneUser } from './users.js';

export type VerificationPurpose = 'register' | 'reset';

const CODE_TTL_SEC = 300;
const MAX_CODE_ATTEMPTS = 5;
const MAX_LOGIN_FAILS = 10;
const LOCK_MINUTES = 15;
/** Проверяется, когда номера нет в базе: время ответа не выдаёт, зарегистрирован ли номер. */
const DUMMY_HASH = hashPassword('astat-phone-login-placeholder');

export function normalizePhone(raw: string): string {
  let d = raw.replace(/\D/g, '');
  if (d.length === 11 && d.startsWith('8')) d = `7${d.slice(1)}`;
  else if (d.length === 10 && d.startsWith('9')) d = `7${d}`;
  if (d.length < 11 || d.length > 15 || d.startsWith('0')) throw badRequest('Укажите номер с кодом страны, например +7 900 000-00-00', 'bad_phone');
  return d;
}

const codeHash = (id: string, code: string) => createHmac('sha256', config().APP_SECRET).update(`phone:${id}:${code}`).digest('hex');
const tooMany = (message: string) => new HttpError(429, message, 'phone_limit');

/** Начать подтверждение. Для незарегистрированного номера при сбросе пароля звонка нет, но ответ такой же. */
export async function startVerification(rawPhone: string, purpose: VerificationPurpose, ip: string) {
  const s = await getSettings('phone_auth');
  if (!s.enabled) throw forbidden('Вход по номеру сейчас отключён');
  if (purpose === 'register') await assertRegistrationOpen();
  const phone = normalizePhone(rawPhone);
  const [known] = await sql()`select 1 from users where phone = ${phone}`;
  const shouldCall = purpose === 'register' || Boolean(known);
  const code = String(randomInt(1000, 10000));

  // Счётчики и запись в одной транзакции под блокировкой: параллельные запросы не обойдут лимиты и не потратят баланс сверх них.
  const id = await sql().begin(async (tx) => {
    await tx`select pg_advisory_xact_lock(hashtext('phone_auth_limits'))`;
    const [c] = await tx`select
      count(*) filter (where phone = ${phone} and created_at > now() - make_interval(secs => ${s.cooldown_sec}))::int as recent,
      count(*) filter (where phone = ${phone})::int as by_phone,
      count(*) filter (where ip = ${ip})::int as by_ip,
      count(*)::int as total
      from phone_verifications where created_at > now() - interval '24 hours'`;
    if (c!.recent > 0) throw tooMany(`Повторный звонок будет доступен через ${s.cooldown_sec} сек.`);
    if (c!.by_phone >= s.max_per_phone_day || c!.by_ip >= s.max_per_ip_day) throw tooMany('Слишком много попыток. Попробуйте завтра.');
    if (c!.total >= s.max_per_day) {
      void alertAdminsThrottled('ucaller_daily_limit', `Достигнут суточный лимит звонков uCaller (${s.max_per_day}). Новые регистрации по номеру приостановлены.`, 3600);
      throw tooMany('Подтверждение номера временно недоступно. Попробуйте позже.');
    }
    const [row] = await tx`insert into phone_verifications (phone, purpose, ip, expires_at)
      values (${phone}, ${purpose}, ${ip}, now() + make_interval(secs => ${CODE_TTL_SEC})) returning id`;
    return row!.id as string;
  });

  if (shouldCall) {
    try {
      const ucallerId = await ucaller.initCall(phone, code, id);
      await sql()`update phone_verifications set code_hash = ${codeHash(id, code)}, ucaller_id = ${ucallerId} where id = ${id}`;
    } catch (e) {
      await sql()`update phone_verifications set consumed_at = now() where id = ${id}`;
      if (e instanceof HttpError && e.code === 'ucaller_1002') void alertAdminsThrottled('ucaller_balance', 'На балансе uCaller закончились деньги: подтверждение номера не работает.', 3600);
      throw e;
    }
  }
  return { id, expiresInSec: CODE_TTL_SEC, retryInSec: s.cooldown_sec };
}

/** Одноразово проверяет код. После пяти ошибок запись больше не принимается. */
async function consumeCode(id: string, code: string, purpose: VerificationPurpose): Promise<string> {
  const [v] = await sql()`update phone_verifications set attempts = attempts + 1
    where id = ${id} and purpose = ${purpose} and consumed_at is null and expires_at > now() and attempts < ${MAX_CODE_ATTEMPTS}
    returning phone, code_hash`;
  if (!v) throw badRequest('Код устарел. Запросите новый звонок.', 'code_expired');
  if (!v.code_hash || !safeEqual(v.code_hash, codeHash(id, code))) throw badRequest('Неверный код. Проверьте последние 4 цифры номера.', 'bad_code');
  const [done] = await sql()`update phone_verifications set consumed_at = now() where id = ${id} and consumed_at is null returning id`;
  if (!done) throw badRequest('Код устарел. Запросите новый звонок.', 'code_expired');
  return v.phone as string;
}

export async function completeRegistration(id: string, code: string, password: string, ref?: string | null): Promise<UserRow> {
  await assertRegistrationOpen();
  const phone = await consumeCode(id, code, 'register');
  const [exists] = await sql()`select 1 from users where phone = ${phone}`;
  if (exists) throw conflict('Этот номер уже зарегистрирован. Войдите или восстановите пароль.', 'phone_taken');
  return createPhoneUser(phone, await hashPassword(password), ref);
}

export async function completeReset(id: string, code: string, password: string): Promise<UserRow> {
  const phone = await consumeCode(id, code, 'reset');
  const hash = await hashPassword(password);
  const [u] = await sql()<UserRow[]>`update users set password_hash = ${hash}, password_changed_at = now(), login_failed = 0, login_locked_until = null
    where phone = ${phone} returning *`;
  if (!u) throw badRequest('Код устарел. Запросите новый звонок.', 'code_expired');
  if (u.status === 'banned') throw forbidden('Аккаунт заблокирован');
  return u;
}

export async function loginWithPassword(rawPhone: string, password: string): Promise<UserRow> {
  const phone = normalizePhone(rawPhone);
  const [u] = await sql()<UserRow[]>`select * from users where phone = ${phone}`;
  if (u?.login_locked_until && u.login_locked_until > new Date()) throw new HttpError(429, 'Слишком много неудачных попыток. Попробуйте позже или восстановите пароль.', 'login_locked');
  const ok = await verifyPassword(password, u?.password_hash ?? (await DUMMY_HASH));
  if (!u?.password_hash || !ok) {
    if (u) await sql()`update users set
      login_failed = case when login_failed + 1 >= ${MAX_LOGIN_FAILS} then 0 else login_failed + 1 end,
      login_locked_until = case when login_failed + 1 >= ${MAX_LOGIN_FAILS} then now() + make_interval(mins => ${LOCK_MINUTES}) else login_locked_until end
      where id = ${u.id}`;
    throw badRequest('Неверный номер или пароль', 'bad_credentials');
  }
  if (u.status === 'banned') throw forbidden('Аккаунт заблокирован');
  await sql()`update users set login_failed = 0, login_locked_until = null, last_seen_at = now() where id = ${u.id}`;
  return u;
}
