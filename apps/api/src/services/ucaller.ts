import { badGateway } from '../lib/errors.js';
import { getSettings } from './settings.js';

const DEFAULT_API = 'https://api.ucaller.ru/v1.0';
const api = () => (process.env.UCALLER_API_URL ?? DEFAULT_API).replace(/\/$/, '');

interface UcallerResponse { status?: boolean; error?: string; code?: number; ucaller_id?: number; rub_balance?: number; tariff_name?: string }

async function request(method: 'GET' | 'POST', path: string, body?: unknown): Promise<UcallerResponse> {
  const s = await getSettings('phone_auth');
  if (!s.service_id || !s.key) throw badGateway('Подтверждение номера не настроено', 'ucaller_not_configured');
  const res = await fetch(`${api()}${path}`, {
    method,
    headers: { authorization: `Bearer ${s.key}.${s.service_id}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15_000),
  });
  const data = (await res.json().catch(() => ({}))) as UcallerResponse;
  if (!res.ok || data.status !== true) {
    throw badGateway('Не удалось выполнить звонок для подтверждения. Попробуйте позже.', `ucaller_${data.code ?? res.status}`, `uCaller ${path}: ${data.code ?? res.status} ${data.error ?? ''}`.trim());
  }
  return data;
}

export const ucaller = {
  /** Звонок на номер: последние 4 цифры входящего номера равны code. requestId защищает от повторного списания. */
  async initCall(phone: string, code: string, requestId: string): Promise<number | null> {
    const r = await request('POST', '/initCall', { phone: Number(phone), code, unique: requestId, client: 'astat' });
    return r.ucaller_id ?? null;
  },
  async ping(): Promise<{ balance: number | null; tariff: string | null }> {
    const r = await request('GET', '/getBalance');
    return { balance: r.rub_balance ?? null, tariff: r.tariff_name ?? null };
  },
};
