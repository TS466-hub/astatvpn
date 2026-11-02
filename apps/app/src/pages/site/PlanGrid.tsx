import { durationLabel, formatRub } from '@vpn/shared';
import { Link } from 'react-router-dom';
import { usePlansPublic } from '../../lib/queries';

export function PlanGrid() {
  const plans = usePlansPublic();
  if (plans.isLoading) return <p className="site-muted">Загружаем тарифы…</p>;
  if (!plans.data?.length) return <p className="site-muted">Тарифы появятся здесь после настройки в админке.</p>;
  return (
    <div className="site-grid site-grid-4">
      {plans.data.map((p) => (
        <article key={p.id} className="site-card site-plan">
          <div className="site-plan-top"><b>{p.name}</b>{p.badge && <span className="site-chip">{p.badge}</span>}</div>
          <div className="site-price">{formatRub(p.price)}</div>
          <div className="site-muted">{durationLabel(p.durationDays)}</div>
          <ul>
            <li>{p.trafficLimitGb ? `${p.trafficLimitGb} ГБ трафика` : 'Безлимитный трафик'}</li>
            <li>{p.deviceLimit ? `До ${p.deviceLimit} устройств` : 'Без лимита устройств'}</li>
          </ul>
          <Link to="/login" className="site-btn site-btn-ghost">Выбрать</Link>
        </article>
      ))}
    </div>
  );
}
