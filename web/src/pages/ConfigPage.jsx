import Field from '../components/Field.jsx';
import ProtocolSelect from '../components/ProtocolSelect.jsx';

export default function ConfigPage({ form, markForm, save, retry, status, statusGuide, mapping, setMapping, addMapping, port, setPort, addPort, config, portRows }) {
  return (
    <>
      {statusGuide}
      <section className="panel form-panel">
        <div className="panel-head"><div><p className="kicker">RUNTIME PROFILE</p><h2>连接与运行配置</h2></div><button className="primary-button" type="button" onClick={save}>{form.dirty || status === 'waiting_for_configuration' ? '保存并启动' : '保存配置'}</button></div>
        <div className="form-grid">
          <Field title="模式"><select value={form.mode || 'client'} onChange={event => markForm({ mode: event.target.value })}><option value="client">Client</option><option value="server">Server</option></select></Field>
          <Field title="Index 地址" hint="留空时由 CA Web 自动发现"><input value={form.index_address || ''} placeholder="host:port" onChange={event => markForm({ index_address: event.target.value })} /></Field>
          <Field title="Relay 地址" hint="可留空由 Index 选择"><input value={form.relay_address || ''} placeholder="host:port" onChange={event => markForm({ relay_address: event.target.value })} /></Field>
          <Field title="Web 监听地址" hint="当前实例的监听地址，需通过启动参数修改"><input disabled value={form.web_listen_address || '0.0.0.0:8088'} placeholder="0.0.0.0:8088" /></Field>
          <Field title="安全档"><select value={form.security_profile || 'production'} onChange={event => markForm({ security_profile: event.target.value })}><option value="production">production</option><option value="staging">staging</option><option value="development">development</option></select></Field>
          <Field title="扣费密钥路径" hint="只保存路径，不上传密钥内容"><input value={form.billing_key_file || ''} placeholder="/secure/billing-key.json" onChange={event => markForm({ billing_key_file: event.target.value })} /></Field>
          <Field title="身份文件路径"><input value={form.identity_file || ''} placeholder="留空自动生成" onChange={event => markForm({ identity_file: event.target.value })} /></Field>
          {form.mode === 'client' ? <Field title="目标 Server NodeID"><input value={form.server_node_id || ''} placeholder="64 位 NodeID" onChange={event => markForm({ server_node_id: event.target.value })} /></Field> : <Field title="默认转发端口" hint="兼容单目标 Server 配置"><input value={form.forward_target || ''} placeholder="127.0.0.1:8080" onChange={event => markForm({ forward_target: event.target.value })} /></Field>}
        </div>
        <div className="form-actions"><button className="secondary-button" type="button" onClick={retry}>重试连接</button><span className="form-note">配置会原子写入 JSON 文件；点击“保存并启动”后自动应用。</span></div>
        {form.mode === 'client' ? (
          <div className="subpanel"><div className="panel-head compact"><h3>Client 本地映射</h3><span className="panel-tag">TCP / UDP</span></div><div className="route-grid"><Field title="协议"><ProtocolSelect value={mapping.protocol} onChange={protocol => setMapping({ ...mapping, protocol })} /></Field><Field title="本地监听"><input value={mapping.listen} onChange={event => setMapping({ ...mapping, listen: event.target.value })} /></Field><Field title="Server 路由键（可选）" hint="留空或 0 时使用单一转发端口"><input type="number" min="0" max="65535" value={mapping.remote_port} onChange={event => setMapping({ ...mapping, remote_port: Number(event.target.value) })} /></Field></div><button className="secondary-button" type="button" onClick={addMapping}>添加映射</button></div>
        ) : (
          <div className="subpanel"><div className="panel-head compact"><div><h3>Server 转发端口</h3><p className="subpanel-note">收到远端流后直接连接这里配置的目标，不会额外监听请求端口。</p></div><span className="panel-tag">TCP / UDP</span></div><div className="route-grid forwarding-grid"><Field title="转发端口"><input value={port.target} placeholder="例如 127.0.0.1:18100" onChange={event => setPort({ ...port, target: event.target.value })} /></Field><Field title="传输协议"><ProtocolSelect value={port.protocol} onChange={protocol => setPort({ ...port, protocol })} /></Field></div><div className="forwarding-action"><button className="secondary-button" type="button" onClick={addPort}>添加转发端口</button></div></div>
        )}
      </section>
      {form.mode === 'server' ? <section className="panel configured-routes-panel"><div className="panel-head"><div><p className="kicker">SERVER FORWARDING</p><h2>转发端口预览</h2></div><span className="panel-tag">{(config.server_ports || []).length} PORTS</span></div><div className="route-list">{portRows || <div className="empty">还没有配置转发端口。填写上方表单并点击“添加转发端口”后会显示在这里。</div>}</div></section> : null}
    </>
  );
}
