import { useEffect, useRef, useState } from 'react';
import { useHistory, useLocation } from 'react-router-dom';
import { jsonHeaders, request } from '../api/client.js';
import LoginPage from '../components/LoginPage.jsx';
import Sidebar from '../components/Sidebar.jsx';
import StatusGuide from '../components/StatusGuide.jsx';
import Topbar from '../components/Topbar.jsx';
import { MappingRows, PortRows } from '../components/RouteRows.jsx';
import OverviewPage from './OverviewPage.jsx';
import ConfigPage from './ConfigPage.jsx';

const initialForm = { mode: 'client', index_address: '', relay_address: '', server_node_id: '', web_listen_address: '0.0.0.0:8088', security_profile: 'production', billing_key_file: '', identity_file: '' };
const initialMapping = { protocol: 'tcp', listen: '127.0.0.1:18080', remote_port: 0 };
const initialPort = { protocol: 'tcp', target: '' };

function forwardingPort(target) {
  const match = String(target || '').trim().match(/:(\d+)$/);
  if (!match) return 0;
  const port = Number(match[1]);
  return Number.isInteger(port) && port > 0 && port <= 65535 ? port : 0;
}

export default function ConsolePage() {
  const section = useLocation().pathname === '/config' ? 'config' : 'overview';
  const history = useHistory();
  const [auth, setAuth] = useState(null);
  const [authError, setAuthError] = useState('');
  const [loginBusy, setLoginBusy] = useState(false);
  const [state, setState] = useState(null);
  const [error, setError] = useState('');
  const [form, setForm] = useState(initialForm);
  const [mapping, setMapping] = useState(initialMapping);
  const [port, setPort] = useState(initialPort);
  const [editing, setEditing] = useState(null);
  const [dirty, setDirty] = useState(false);
  const dirtyRef = useRef(false);

  const load = () => request('/api/status').then(snapshot => {
    setState(snapshot);
    if (!dirtyRef.current) setForm({ ...snapshot.config });
    setError('');
  }).catch(err => {
    if (err.status === 401) setAuth(previous => previous ? { ...previous, authenticated: false } : previous);
    setError(String(err.message || err));
  });

  useEffect(() => {
    request('/api/auth/status').then(status => { setAuth(status); if (!status.required || status.authenticated) load(); }).catch(err => setAuthError(String(err.message || err)));
  }, []);
  useEffect(() => {
    if (!auth || (auth.required && !auth.authenticated)) return undefined;
    const timer = setInterval(load, 3000);
    return () => clearInterval(timer);
  }, [auth?.authenticated, auth?.required]);

  const login = (username, password) => {
    setLoginBusy(true); setAuthError('');
    request('/api/auth/login', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ username, password }) }).then(status => { setAuth({ required: true, authenticated: true, user: status.user }); load(); }).catch(err => setAuthError(String(err.message || err))).finally(() => setLoginBusy(false));
  };
  const logout = () => request('/api/auth/logout', { method: 'POST' }).finally(() => setAuth(previous => previous ? { ...previous, authenticated: false } : previous));
  const markForm = patch => { dirtyRef.current = true; setDirty(true); setForm(previous => ({ ...previous, ...patch })); };
  const save = () => request('/api/config', { method: 'PUT', headers: jsonHeaders, body: JSON.stringify(form) }).then(snapshot => { dirtyRef.current = false; setDirty(false); setState(snapshot); setError(''); }).catch(err => setError(String(err.message || err)));
  const retry = () => request('/api/retry', { method: 'POST' }).then(snapshot => { setState(snapshot); setError(''); }).catch(err => setError(String(err.message || err)));
  const addMapping = () => request('/api/client/mappings', { method: 'POST', headers: jsonHeaders, body: JSON.stringify(mapping) }).then(() => { setMapping(initialMapping); load(); }).catch(err => setError(String(err.message || err)));
  const removeMapping = id => request(`/api/client/mappings/${encodeURIComponent(id)}`, { method: 'DELETE' }).then(load).catch(err => setError(String(err.message || err)));
  const updateMapping = item => request(`/api/client/mappings/${encodeURIComponent(item.id)}`, { method: 'PUT', headers: jsonHeaders, body: JSON.stringify(item) }).then(() => { setEditing(null); load(); }).catch(err => setError(String(err.message || err)));
  const addPort = () => {
    const portNumber = forwardingPort(port.target);
    if (!portNumber) { setError('转发端口必须填写 host:port 格式，例如 127.0.0.1:8080'); return; }
    request('/api/server/ports', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ ...port, port: portNumber }) }).then(() => { setPort(initialPort); load(); }).catch(err => setError(String(err.message || err)));
  };
  const removePort = id => request(`/api/server/ports/${encodeURIComponent(id)}`, { method: 'DELETE' }).then(load).catch(err => setError(String(err.message || err)));
  const updatePort = item => {
    const portNumber = forwardingPort(item.target);
    if (!portNumber) { setError('转发端口必须填写 host:port 格式，例如 127.0.0.1:8080'); return; }
    request(`/api/server/ports/${encodeURIComponent(item.id)}`, { method: 'PUT', headers: jsonHeaders, body: JSON.stringify({ ...item, port: portNumber }) }).then(() => { setEditing(null); load(); }).catch(err => setError(String(err.message || err)));
  };

  if (!auth) return <div className="loading-screen"><span className="spinner" />正在连接控制台…</div>;
  if (auth.required && !auth.authenticated) return <LoginPage onLogin={login} error={authError} busy={loginBusy} />;

  const config = state ? state.config : form;
  const status = state ? state.status : 'loading';
  const statusGood = status === 'running';
  const statusGuide = <StatusGuide status={status} config={config} lastError={state?.last_error} onGoToConfig={() => history.push('/config')} />;
  const mappingRows = (config.client_mappings || []).length ? <MappingRows items={config.client_mappings} editing={editing} setEditing={setEditing} onRemove={removeMapping} onUpdate={updateMapping} /> : null;
  const portRows = (config.server_ports || []).length ? <PortRows items={config.server_ports} editing={editing} setEditing={setEditing} onRemove={removePort} onUpdate={updatePort} /> : null;

  return (
    <div className="app-shell">
      <Sidebar statusGood={statusGood} webAddress={config.web_listen_address} onLogout={logout} />
      <main className="main">
        <Topbar title={section === 'overview' ? '运行概览' : '节点配置'} status={status} statusGood={statusGood} />
        <div className="content">{error ? <div className="toast error">{error}</div> : null}{section === 'overview' ? <OverviewPage config={config} status={status} statusGood={statusGood} dirty={dirty} statusGuide={statusGuide} mappingRows={mappingRows} portRows={portRows} /> : <ConfigPage form={{ ...form, dirty }} markForm={markForm} save={save} retry={retry} status={status} statusGuide={statusGuide} mapping={mapping} setMapping={setMapping} addMapping={addMapping} port={port} setPort={setPort} addPort={addPort} config={config} portRows={portRows} />}</div>
      </main>
    </div>
  );
}
