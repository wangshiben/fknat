import Field from './Field.jsx';
import ProtocolSelect from './ProtocolSelect.jsx';

function MappingEditor({ value, onChange, onSave, onCancel }) {
  return (
    <div className="route-row editing">
      <div className="route-grid">
        <Field title="协议"><ProtocolSelect value={value.protocol} onChange={protocol => onChange({ protocol })} /></Field>
        <Field title="本地监听"><input value={value.listen} onChange={event => onChange({ listen: event.target.value })} /></Field>
        <Field title="Server 路由键（可选）" hint="留空或 0 时使用单一转发端口"><input type="number" min="0" max="65535" value={value.remote_port} onChange={event => onChange({ remote_port: Number(event.target.value) })} /></Field>
      </div>
      <div className="row-actions"><button className="primary-button small" type="button" onClick={onSave}>保存</button><button className="quiet-button" type="button" onClick={onCancel}>取消</button></div>
    </div>
  );
}

function PortEditor({ value, onChange, onSave, onCancel }) {
  return (
    <div className="route-row editing">
      <div className="route-grid forwarding-grid">
        <Field title="转发端口"><input value={value.target} placeholder="例如 127.0.0.1:18100" onChange={event => onChange({ target: event.target.value })} /></Field>
        <Field title="传输协议"><ProtocolSelect value={value.protocol} onChange={protocol => onChange({ protocol })} /></Field>
      </div>
      <div className="row-actions"><button className="primary-button small" type="button" onClick={onSave}>保存</button><button className="quiet-button" type="button" onClick={onCancel}>取消</button></div>
    </div>
  );
}

export function MappingRows({ items, editing, setEditing, onRemove, onUpdate }) {
  return items.map(item => {
    if (editing?.kind === 'mapping' && editing.value.id === item.id) {
      const change = patch => setEditing({ kind: 'mapping', value: { ...editing.value, ...patch } });
      return <MappingEditor key={item.id} value={editing.value} onChange={change} onSave={() => onUpdate(editing.value)} onCancel={() => setEditing(null)} />;
    }
    return (
      <div className="route-row" key={item.id}>
        <div><strong>{(item.protocol || 'tcp').toUpperCase()} {item.listen} → Server {item.remote_port || '默认'}</strong><small>{item.enabled ? 'ACTIVE' : 'DISABLED'}</small></div>
        <div className="row-actions"><button className="quiet-button" type="button" onClick={() => setEditing({ kind: 'mapping', value: { ...item } })}>编辑</button><button className="danger-button" type="button" onClick={() => onRemove(item.id)}>删除</button></div>
      </div>
    );
  });
}

export function PortRows({ items, editing, setEditing, onRemove, onUpdate }) {
  return items.map(item => {
    if (editing?.kind === 'port' && editing.value.id === item.id) {
      const change = patch => setEditing({ kind: 'port', value: { ...editing.value, ...patch } });
      return <PortEditor key={item.id} value={editing.value} onChange={change} onSave={() => onUpdate(editing.value)} onCancel={() => setEditing(null)} />;
    }
    return (
      <div className="route-row" key={item.id}>
        <div><strong>{(item.protocol || 'tcp').toUpperCase()} · 转发端口 {item.target}</strong><small>{item.enabled ? 'RECEIVE AND DISPATCH' : 'DISABLED'}</small></div>
        <div className="row-actions"><button className="quiet-button" type="button" onClick={() => setEditing({ kind: 'port', value: { ...item } })}>编辑</button><button className="danger-button" type="button" onClick={() => onRemove(item.id)}>删除</button></div>
      </div>
    );
  });
}
