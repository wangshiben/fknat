export default function OverviewPage({ config, status, statusGood, dirty, statusGuide, mappingRows, portRows }) {
  return (
    <>
      <section className="stats-grid">
        <article className="stat-card accent"><p>运行状态</p><strong>{status}</strong><small>{config.mode || '未选择模式'}</small></article>
        <article className="stat-card"><p>节点角色</p><strong>{config.mode ? config.mode.toUpperCase() : '—'}</strong><small>{config.server_node_id ? `${config.server_node_id.slice(0, 16)}…` : '等待 NodeID'}</small></article>
        <article className="stat-card"><p>入口 Relay</p><strong>{config.relay_address || 'INDEX'}</strong><small>{config.index_address || 'CA 自动发现'}</small></article>
      </section>
      {statusGuide}
      <section className="panel">
        <div className="panel-head"><div><p className="kicker">LIVE CONFIGURATION</p><h2>连接参数</h2></div><span className={statusGood ? 'panel-tag success' : 'panel-tag'}>{dirty ? 'UNSAVED' : 'SYNCED'}</span></div>
        <div className="config-summary"><div><span>Web</span><code>{config.web_listen_address || '0.0.0.0:8088'}</code></div><div><span>Index</span><code>{config.index_address || 'CA DISCOVERY'}</code></div><div><span>Security</span><code>{config.security_profile || 'production'}</code></div></div>
      </section>
      {config.mode === 'client' ? (
        <section className="panel"><div className="panel-head"><div><p className="kicker">CLIENT ROUTES</p><h2>本地映射</h2></div><span className="panel-tag">{(config.client_mappings || []).length} ROUTES</span></div><div className="route-list">{mappingRows || <div className="empty">还没有本地映射</div>}</div></section>
      ) : (
        <section className="panel"><div className="panel-head"><div><p className="kicker">SERVER FORWARDING</p><h2>转发端口预览</h2></div><span className="panel-tag">{(config.server_ports || []).length} PORTS</span></div><div className="route-list">{portRows || <div className="empty">还没有配置转发端口</div>}</div></section>
      )}
    </>
  );
}
