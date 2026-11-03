import { readPendingGift } from '../lib/gift-links';
import { Button, Spinner } from '@vpn/ui';
import { Eye, EyeOff, Send } from 'lucide-react';
import { QRCodeSVG } from 'qrcode.react';
import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { AsciiHands } from '../components/ascii';
import { errorText, get, post } from '../lib/api';
import { useAuth } from '../lib/auth';
import { useConfig } from '../lib/queries';

type Mode = 'login' | 'register' | 'reset' | 'code' | 'telegram';
type Purpose = 'register' | 'reset';

const readRef = (sp: URLSearchParams) => {
  let ref = sp.get('ref');
  try { ref = ref ?? sessionStorage.getItem('ref'); } catch { /* приватный режим */ }
  return ref ?? undefined;
};

/** Вход через бота: без виджета и без паролей */
function TelegramLogin({ onDone }: { onDone: (token: string) => void }) {
  const [sp] = useSearchParams();
  const [link, setLink] = useState<{ token: string; url: string | null } | null>(null);
  const [error, setError] = useState('');
  const [expired, setExpired] = useState(false);
  const timer = useRef<ReturnType<typeof setInterval>>();

  const start = useCallback(async () => {
    setError('');
    setExpired(false);
    try {
      setLink(await post('/auth/tglink/start', { ref: readRef(sp) }));
    } catch (e) {
      setError(errorText(e));
    }
  }, [sp]);
  useEffect(() => void start(), [start]);

  useEffect(() => {
    if (!link) return;
    timer.current = setInterval(async () => {
      try {
        const r = await get<{ status: 'pending' | 'ok' | 'expired'; accessToken?: string }>(`/auth/tglink/${link.token}`);
        if (r.status === 'ok' && r.accessToken) {
          clearInterval(timer.current);
          onDone(r.accessToken);
        } else if (r.status === 'expired') {
          clearInterval(timer.current);
          setExpired(true);
        }
      } catch {
        /* повторим */
      }
    }, 2000);
    return () => clearInterval(timer.current);
  }, [link, onDone]);

  return (
    <div className="auth-telegram">
      <p className="auth-note">Нажмите кнопку, откройте бота и нажмите «Запустить»: вы войдёте автоматически.</p>
      {error ? <p className="auth-error" role="alert">{error}</p> : !link ? <Spinner className="mx-auto" /> : expired ? (
        <Button full onClick={start}>Ссылка устарела, обновить</Button>
      ) : (
        <>
          {link.url ? <a href={link.url} target="_blank" rel="noreferrer" className="site-btn auth-submit"><Send className="h-4 w-4" /> Открыть Telegram</a> : <p className="auth-error">Бот не настроен (BOT_USERNAME).</p>}
          {link.url && <div className="auth-qr"><QRCodeSVG value={link.url} size={148} /></div>}
          <div className="auth-note auth-wait"><Spinner className="h-4 w-4" /> Ждём подтверждения в боте…</div>
        </>
      )}
    </div>
  );
}

function PasswordField({ label, value, onChange, autoComplete }: { label: string; value: string; onChange: (v: string) => void; autoComplete: string }) {
  const [shown, setShown] = useState(false);
  return (
    <label className="auth-field">
      <span>{label}</span>
      <div className="auth-password">
        <input type={shown ? 'text' : 'password'} value={value} onChange={(e) => onChange(e.target.value)} autoComplete={autoComplete} required />
        <button type="button" onClick={() => setShown(!shown)} aria-label={shown ? 'Скрыть пароль' : 'Показать пароль'}>{shown ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>
      </div>
    </label>
  );
}

function CodeInput({ value, onChange, disabled }: { value: string; onChange: (v: string) => void; disabled: boolean }) {
  return (
    <div className="auth-code">
      <input aria-label="Последние 4 цифры номера" inputMode="numeric" autoComplete="one-time-code" autoFocus disabled={disabled} maxLength={4} value={value} onChange={(e) => onChange(e.target.value.replace(/\D/g, '').slice(0, 4))} />
      {[0, 1, 2, 3].map((i) => <span key={i} className={value.length === i ? 'on' : ''}>{value[i] ?? ''}</span>)}
    </div>
  );
}

export default function Login() {
  const { login } = useAuth();
  const nav = useNavigate();
  const [sp] = useSearchParams();
  const cfg = useConfig();
  const brand = cfg.data?.brandName ?? 'ASTAT';
  const phoneEnabled = cfg.data?.phoneAuthEnabled ?? false;

  const [mode, setMode] = useState<Mode>('login');
  const [phone, setPhone] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState<{ id: string; purpose: Purpose } | null>(null);
  const [retryIn, setRetryIn] = useState(0);

  useEffect(() => {
    if (retryIn <= 0) return;
    const t = setTimeout(() => setRetryIn(retryIn - 1), 1000);
    return () => clearTimeout(t);
  }, [retryIn]);

  const finish = useCallback((token: string) => {
    login(token);
    nav(readPendingGift() || sp.get('next') === '/gifts?receive=1' ? '/gifts?receive=1' : '/', { replace: true });
  }, [login, nav, sp]);

  const go = (next: Mode) => { setMode(next); setError(''); setCode(''); };

  const requestCall = async (purpose: Purpose) => {
    setError('');
    setBusy(true);
    try {
      const r = await post<{ id: string; retryInSec: number }>('/auth/phone/start', { phone, purpose });
      setPending({ id: r.id, purpose });
      setRetryIn(r.retryInSec);
      setCode('');
      setMode('code');
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (mode === 'login') {
      setError('');
      setBusy(true);
      try {
        finish((await post<{ accessToken: string }>('/auth/phone/login', { phone, password })).accessToken);
      } catch (err) {
        setError(errorText(err));
      } finally {
        setBusy(false);
      }
      return;
    }
    if (password.length < 8) return setError('Пароль должен быть не короче 8 символов');
    await requestCall(mode === 'reset' ? 'reset' : 'register');
  };

  const confirm = useCallback(async (value: string) => {
    if (!pending || value.length !== 4) return;
    setError('');
    setBusy(true);
    try {
      const body = pending.purpose === 'register' ? { id: pending.id, code: value, password, ref: readRef(sp) } : { id: pending.id, code: value, password };
      finish((await post<{ accessToken: string }>(`/auth/phone/${pending.purpose}`, body)).accessToken);
    } catch (err) {
      setError(errorText(err));
      setCode('');
    } finally {
      setBusy(false);
    }
  }, [pending, password, sp, finish]);

  const showTelegram = !phoneEnabled || mode === 'telegram';
  const heading = showTelegram ? 'Вход через Telegram' : mode === 'login' ? 'Вход' : mode === 'register' ? 'Создание аккаунта' : mode === 'reset' ? 'Новый пароль' : 'Подтвердите номер';

  return (
    <div className="auth">
      <aside className="auth-art">
        <Link to="/" className="site-logo">[ {brand} ]</Link>
        <AsciiHands />
        <div className="auth-art-copy">
          <h2>Связь не зависит от Telegram</h2>
          <p>Аккаунт на сайте работает даже там, где мессенджер недоступен.</p>
        </div>
      </aside>
      <main className="auth-main">
        <div className="auth-box">
          <div className="site-tag">{heading}</div>
          {cfg.isLoading ? <Spinner className="mx-auto" /> : showTelegram ? (
            <>
              <TelegramLogin onDone={finish} />
              {phoneEnabled && <button type="button" className="site-btn site-btn-ghost auth-submit" onClick={() => go('login')}>Войти по номеру телефона</button>}
            </>
          ) : mode === 'code' ? (
            <>
              <p className="auth-note">Вам позвонят. Отвечать не нужно: введите последние 4 цифры входящего номера.</p>
              <CodeInput value={code} disabled={busy} onChange={(v) => { setCode(v); setError(''); if (v.length === 4) void confirm(v); }} />
              {error && <p className="auth-error" role="alert">{error}</p>}
              <button type="button" className="site-btn site-btn-ghost auth-submit" disabled={busy || retryIn > 0} onClick={() => pending && void requestCall(pending.purpose)}>
                {retryIn > 0 ? `Позвонить снова через 0:${String(retryIn % 60).padStart(2, '0')}`.replace('0:', `${Math.floor(retryIn / 60)}:`) : 'Позвонить снова'}
              </button>
              <button type="button" className="auth-link" onClick={() => go(pending?.purpose === 'reset' ? 'reset' : 'register')}>Изменить номер</button>
            </>
          ) : (
            <form onSubmit={submit}>
              <label className="auth-field">
                <span>Телефон с кодом страны</span>
                <input type="tel" inputMode="tel" autoComplete="tel" placeholder="+7 900 000-00-00" value={phone} onChange={(e) => setPhone(e.target.value)} required />
              </label>
              <PasswordField label={mode === 'login' ? 'Пароль' : mode === 'reset' ? 'Новый пароль' : 'Придумайте пароль'} value={password} onChange={setPassword} autoComplete={mode === 'login' ? 'current-password' : 'new-password'} />
              {mode !== 'login' && <p className="auth-hint">Не короче 8 символов</p>}
              {error && <p className="auth-error" role="alert">{error}</p>}
              <button type="submit" className="site-btn auth-submit" disabled={busy}>{busy ? 'Подождите…' : mode === 'login' ? 'Войти' : 'Получить звонок'}</button>
              <button type="button" className="site-btn site-btn-ghost auth-submit" onClick={() => go('telegram')}>Войти через Telegram</button>
              <div className="auth-links">
                {mode === 'login' ? (
                  <>
                    <button type="button" className="auth-link" onClick={() => go('register')}>Создать аккаунт</button>
                    <button type="button" className="auth-link" onClick={() => go('reset')}>Восстановить пароль</button>
                  </>
                ) : <button type="button" className="auth-link" onClick={() => go('login')}>Уже есть аккаунт? Войти</button>}
              </div>
            </form>
          )}
        </div>
      </main>
    </div>
  );
}
