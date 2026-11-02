import { useEffect, type ReactNode } from 'react';
import { Link, NavLink } from 'react-router-dom';
import { ClosureBanner } from '../../components/Closure';
import { useConfig } from '../../lib/queries';

const NAV = [
  { to: '/pricing', label: 'Тарифы' },
  { to: '/download', label: 'Подключение' },
  { to: '/faq', label: 'Вопросы' },
  { to: '/contacts', label: 'Контакты' },
];

/** Общий каркас публичных страниц сайта: шапка, подвал и заголовок вкладки. */
export function SiteLayout({ title, children }: { title?: string; children: ReactNode }) {
  const cfg = useConfig();
  const brand = cfg.data?.brandName ?? 'ASTAT';
  useEffect(() => {
    document.title = title ? `${title} — ${brand}` : `${brand} — VPN для всех устройств`;
    window.scrollTo(0, 0);
  }, [title, brand]);
  return (
    <div className="site">
      <header className="site-head">
        <Link to="/" className="site-logo">[ {brand} ]</Link>
        <nav className="site-nav">
          {NAV.map((n) => <NavLink key={n.to} to={n.to}>{n.label}</NavLink>)}
        </nav>
        <Link to="/login" className="site-btn site-btn-sm">Войти</Link>
      </header>
      <div className="site-wrap"><ClosureBanner full /></div>
      <main>{children}</main>
      <footer className="site-foot">
        <span>© {new Date().getFullYear()} {brand}</span>
        <nav>
          <Link to="/terms">Оферта</Link>
          <Link to="/privacy">Конфиденциальность</Link>
          <Link to="/contacts">Контакты</Link>
        </nav>
      </footer>
    </div>
  );
}

export function PageHead({ tag, title, text }: { tag: string; title: string; text?: string }) {
  return (
    <div className="site-wrap site-pagehead">
      <div className="site-tag">{tag}</div>
      <h1>{title}</h1>
      {text && <p>{text}</p>}
    </div>
  );
}
