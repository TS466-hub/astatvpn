import { Link } from 'react-router-dom';
import { AsciiGlobe, AsciiHands } from '../components/ascii';
import { useConfig } from '../lib/queries';
import { PlanGrid } from './site/PlanGrid';
import { SiteLayout } from './site/SiteLayout';

const FEATURES = [
  { n: '01', title: 'Скорость', text: 'Современный протокол VLESS + Reality: соединение остаётся быстрым и стабильным.' },
  { n: '02', title: 'Приватность', text: 'Трафик шифруется на пути от устройства до сервера.' },
  { n: '03', title: 'Локации', text: 'Серверы в разных странах, сервер меняется прямо в приложении.' },
  { n: '04', title: 'Все устройства', text: 'iPhone, Android, Windows, macOS и Linux по одной подписке.' },
  { n: '05', title: 'В один тап', text: 'Подписка добавляется в приложение кнопкой, без ручных настроек.' },
  { n: '06', title: 'Поддержка', text: 'Отвечаем в Telegram и помогаем с подключением.' },
];
const STEPS = [
  { n: '1', title: 'Войдите', text: 'Через Telegram-бота или на сайте. Новым пользователям доступен пробный период.' },
  { n: '2', title: 'Установите приложение', text: 'Кабинет подскажет подходящий клиент для вашего устройства.' },
  { n: '3', title: 'Подключитесь', text: 'Нажмите кнопку: подписка добавится сама, останется включить VPN.' },
];

export default function Landing() {
  const cfg = useConfig();
  const bot = cfg.data?.botUsername;
  return (
    <SiteLayout>
      <section className="site-hero">
        <AsciiHands />
        <div className="site-wrap site-hero-copy">
          <div className="site-tag">Соединение установлено</div>
          <h1>Между вами и&nbsp;интернетом — только&nbsp;связь</h1>
          <p>Подключитесь за минуту: начните с пробного периода, добавьте подписку в приложение, и всё работает.</p>
          <div className="site-actions">
            <Link to="/login" className="site-btn">Начать бесплатно</Link>
            {bot && <a href={`https://t.me/${bot}`} target="_blank" rel="noreferrer" className="site-btn site-btn-ghost">Открыть бота</a>}
          </div>
        </div>
      </section>

      <section className="site-wrap site-section">
        <h2><span>//</span> Что внутри</h2>
        <div className="site-grid site-grid-3">
          {FEATURES.map((f) => (
            <article key={f.n} className="site-card"><div className="site-num">{f.n}</div><h3>{f.title}</h3><p>{f.text}</p></article>
          ))}
        </div>
      </section>

      <section className="site-wrap site-section site-split">
        <div>
          <h2><span>//</span> Три шага</h2>
          <ol className="site-steps">
            {STEPS.map((s) => <li key={s.n}><b>{s.n}</b><div><h3>{s.title}</h3><p>{s.text}</p></div></li>)}
          </ol>
        </div>
        <AsciiGlobe />
      </section>

      <section className="site-wrap site-section">
        <h2><span>//</span> Тарифы</h2>
        <PlanGrid />
      </section>
    </SiteLayout>
  );
}
