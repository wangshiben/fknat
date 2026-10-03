export default function Topbar({ title, status, statusGood }) {
  return (
    <header className="topbar">
      <div><p className="eyebrow">NODE CONTROL PLANE</p><h1>{title}</h1><p className="topbar-subtitle">通过安全会话管理本机 fknat 转发节点。</p></div>
      <div className={statusGood ? 'health-pill' : 'health-pill offline'}><i />{statusGood ? 'ONLINE' : String(status).toUpperCase()}</div>
    </header>
  );
}
