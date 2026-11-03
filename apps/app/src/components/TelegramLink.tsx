import { Link2, Loader2, Send } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useToast } from '@vpn/ui';
import { errorText, get, post } from '../lib/api';
import { useAuth } from '../lib/auth';

/** Связка аккаунта по номеру с Telegram: объединение подтверждается в боте, затем сайт получает новый токен. */
export function TelegramLink() {
  const { login } = useAuth();
  const toast = useToast();
  const [link, setLink] = useState<{ token: string; url: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!link) return;
    const t = setInterval(async () => {
      try {
        const r = await get<{ status: 'pending' | 'ok' | 'expired'; accessToken?: string }>(`/auth/tglink/${link.token}`);
        if (r.status === 'ok' && r.accessToken) {
          clearInterval(t);
          login(r.accessToken);
          toast('Аккаунты связаны', 'success');
        } else if (r.status === 'expired') {
          clearInterval(t);
          setLink(null);
          setError('Ссылка устарела. Попробуйте ещё раз.');
        }
      } catch {
        /* повторим */
      }
    }, 2000);
    return () => clearInterval(t);
  }, [link, login, toast]);

  const start = async () => {
    setBusy(true);
    setError('');
    try {
      setLink(await post('/me/telegram-link'));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="tg-link" aria-label="Связать с Telegram">
      <span className="signature-icon"><Link2 /></span>
      <div className="tg-link-text">
        <b>Связать с Telegram</b>
        <p>{link ? 'Откройте бота и подтвердите объединение. Страница обновится сама.' : 'Баланс и подписка объединятся, а входить можно будет обоими способами.'}</p>
        {error && <p className="auth-error" role="alert">{error}</p>}
      </div>
      {link ? (
        <a className="site-btn site-btn-sm tg-link-btn" href={link.url} target="_blank" rel="noreferrer"><Send className="h-4 w-4" /> Открыть бота</a>
      ) : (
        <button type="button" className="site-btn site-btn-sm tg-link-btn" disabled={busy} onClick={() => void start()}>{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Связать'}</button>
      )}
    </section>
  );
}
