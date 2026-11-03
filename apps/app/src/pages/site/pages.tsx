import { Link } from 'react-router-dom';
import { useConfig } from '../../lib/queries';
import { PlanGrid } from './PlanGrid';
import { PageHead, SiteLayout } from './SiteLayout';

export function PricingPage() {
  return (
    <SiteLayout title="Тарифы">
      <PageHead tag="Тарифы" title="Одна подписка на все устройства" text="Оплата картой, через СБП или с баланса. Способы оплаты показываем перед покупкой." />
      <section className="site-wrap site-section site-section-tight"><PlanGrid /></section>
    </SiteLayout>
  );
}

const PLATFORMS = [
  { name: 'iPhone и iPad', apps: 'Happ, Streisand, Karing' },
  { name: 'Android', apps: 'Happ, Hiddify, Karing' },
  { name: 'Windows', apps: 'Hiddify, Happ' },
  { name: 'macOS', apps: 'Hiddify, Happ, Streisand' },
  { name: 'Linux', apps: 'Hiddify' },
];

export function DownloadPage() {
  return (
    <SiteLayout title="Подключение">
      <PageHead tag="Подключение" title="Работает там, где вы" text="Войдите в кабинет и откройте «Подключить устройство»: там будут ссылки на приложения и кнопка добавления подписки." />
      <section className="site-wrap site-section site-section-tight">
        <div className="site-grid site-grid-3">
          {PLATFORMS.map((p) => <article key={p.name} className="site-card"><h3>{p.name}</h3><p>{p.apps}</p></article>)}
        </div>
        <div className="site-actions"><Link to="/login" className="site-btn">Перейти в кабинет</Link></div>
      </section>
    </SiteLayout>
  );
}

const FAQ = [
  ['Как начать пользоваться?', 'Войдите через Telegram или на сайте, активируйте пробный период и нажмите «Подключить устройство» в кабинете.'],
  ['Сколько устройств можно подключить?', 'Лимит указан в описании тарифа. Дополнительные устройства можно докупить в кабинете.'],
  ['Как оплатить?', 'Доступные способы показываются на шаге оплаты. Можно пополнить баланс и включить автопродление.'],
  ['Можно ли сменить сервер?', 'Да, список локаций находится в приложении-клиенте после добавления подписки.'],
  ['Что делать, если не подключается?', 'Откройте раздел «Помощь» в кабинете: там есть диагностика и чат с поддержкой.'],
  ['Как отключить автопродление?', 'В кабинете, в разделе «Баланс». Автопродление выключается одним переключателем.'],
];

export function FaqPage() {
  return (
    <SiteLayout title="Вопросы и ответы">
      <PageHead tag="FAQ" title="Вопросы и ответы" />
      <section className="site-wrap site-section site-section-tight site-faq">
        {FAQ.map(([q, a]) => <details key={q}><summary>{q}</summary><p>{a}</p></details>)}
      </section>
    </SiteLayout>
  );
}

export function ContactsPage() {
  const cfg = useConfig();
  const bot = cfg.data?.botUsername, support = cfg.data?.supportUrl;
  return (
    <SiteLayout title="Контакты">
      <PageHead tag="Контакты" title="На связи в Telegram" text="Быстрее всего ответим в поддержке. Пользователям с подпиской доступен чат прямо в кабинете." />
      <section className="site-wrap site-section site-section-tight">
        <div className="site-actions">
          {support && <a href={support} className="site-btn" target="_blank" rel="noreferrer">Написать в поддержку</a>}
          {bot && <a href={`https://t.me/${bot}`} className="site-btn site-btn-ghost" target="_blank" rel="noreferrer">@{bot}</a>}
          {!support && !bot && <p className="site-muted">Контакты задаются в админке, в настройках.</p>}
        </div>
      </section>
    </SiteLayout>
  );
}

/* ЧЕРНОВИК: перед запуском замените [в скобках] на свои данные и согласуйте текст с юристом. */
export function TermsPage() {
  return (
    <SiteLayout title="Публичная оферта">
      <PageHead tag="Документы" title="Публичная оферта" />
      <section className="site-wrap site-section site-section-tight site-doc">
        <p>Исполнитель: Команда ASTAT.</p>
        <h3>1. Предмет</h3><p>Исполнитель предоставляет Пользователю доступ к сервису на срок и условиях выбранного тарифа.</p>
        <h3>2. Оплата</h3><p>Стоимость указана на странице тарифов. Доступ открывается после подтверждения оплаты. Автопродление включается и отключается Пользователем в кабинете.</p>
        <h3>3. Возврат</h3><p>Осуществляется только при простое более 7 дней</p>
        <h3>4. Использование</h3><p>Пользователь обязуется соблюдать применимое законодательство и не использовать сервис для противоправных действий.</p>
        <h3>5. Ответственность</h3><p>Сервис не берет ответственность за вас при нарушении наших правил и/или законодательства страны вашего проживания.</p>
      </section>
    </SiteLayout>
  );
}

export function PrivacyPage() {
  return (
    <SiteLayout title="Конфиденциальность">
      <PageHead tag="Документы" title="Политика конфиденциальности" />
      <section className="site-wrap site-section site-section-tight site-doc">
        <p>Оператор: [наименование / ФИО, ИНН, контакты].</p>
        <h3>Какие данные мы обрабатываем</h3><p>Идентификатор и имя в Telegram, номер телефона при регистрации на сайте (для звонка с кодом он передаётся сервису uCaller), сведения о подписке, платежах и обращениях в поддержку.</p>
        <h3>Зачем</h3><p>Для предоставления доступа, приёма оплаты, поддержки и уведомлений о подписке.</p>
        <h3>Хранение и передача</h3>
        <p>Данные аккаунта, подписок и платежей хранятся на нашем сервере. Через VPN-серверы проходит ваш трафик, но его содержимое мы не сохраняем. Технические журналы VPN-серверов содержат IP-адрес подключения и адреса сайтов, с которыми устанавливается соединение, и используются только для диагностики сбоев.</p>
        <p>Сроки хранения: данные аккаунта хранятся, пока аккаунт существует, и удаляются в течение 30 дней после запроса на удаление. Сведения о платежах хранятся столько, сколько требует законодательство о бухгалтерском учёте. Записи о звонках для подтверждения номера удаляются через 30 дней, резервные копии базы через 14 дней.</p>
        <p>Мы передаём данные только тем, без кого сервис не работает: сервису uCaller (номер телефона для звонка с кодом), платёжным системам (данные, необходимые для оплаты), Telegram (если вы пользуетесь ботом) и хостинг-провайдерам, на оборудовании которых работают наши серверы. Мы не продаём данные и не передаём их для рекламы.</p>
        <h3>Ваши права</h3><p>Вы можете запросить доступ к своим данным или их удаление, написав в поддержку.</p>
      </section>
    </SiteLayout>
  );
}
