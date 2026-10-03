(() => {
  const h = React.createElement;
  const jsonHeaders = { 'Content-Type': 'application/json' };
  const { BrowserRouter, Redirect, Route, Switch, NavLink, useHistory, useLocation } = ReactRouterDOM;

  function request(url, options = {}) {
    return fetch(url, Object.assign({ credentials: 'same-origin' }, options)).then(async response => {
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        const error = new Error(body.error || body.message || `HTTP ${response.status}`);
        error.status = response.status;
        throw error;
      }
      return body;
    });
  }

  function Field({ title, hint, children }) {
    return h('label', { className: 'field' }, h('span', null, title), children, hint ? h('small', null, hint) : null);
  }

  function Login({ onLogin, error, busy }) {
    const [username, setUsername] = React.useState('');
    const [password, setPassword] = React.useState('');
    const [showPassword, setShowPassword] = React.useState(false);
    const submit = event => {
      event.preventDefault();
      onLogin(username, password);
    };
    return h('div', { className: 'login-layer' },
      h('div', { className: 'auth-layout' },
        h('section', { className: 'auth-story' },
          h('a', { className: 'brand', href: '/overview' }, h('span', { className: 'brand-mark' }, h('i')), h('span', null, h('strong', null, 'fknat'), h('small', null, 'NATIVE TUNNEL CONTROL'))),
          h('div', { className: 'auth-copy' }, h('p', { className: 'kicker' }, 'SECURE NODE CONSOLE'), h('h1', null, '让每条连接，清晰可控。'), h('p', null, '管理 Node、Relay、端口映射和运行状态。控制台会通过后端会话保护配置与运行操作。')),
          h('div', { className: 'auth-features' },
            h('div', { className: 'auth-feature' }, h('span', null, '01'), h('div', null, h('strong', null, 'Session protected'), h('small', null, '登录状态由 QuicFrameWork Session 管理'))),
            h('div', { className: 'auth-feature' }, h('span', null, '02'), h('div', null, h('strong', null, 'Route aware'), h('small', null, '每条映射都带有明确的转发端口'))),
            h('div', { className: 'auth-feature' }, h('span', null, '03'), h('div', null, h('strong', null, 'Production ready'), h('small', null, '配置原子写入，状态实时刷新')))
          )
        ),
        h('form', { className: 'login-card', onSubmit: submit },
          h('p', { className: 'kicker' }, 'WEB ACCESS'),
          h('h2', null, '登录控制台'),
          h('p', { className: 'login-lead' }, '输入启动参数中配置的 Web 用户名和密码。'),
          h(Field, { title: '用户名' }, h('input', { autoFocus: true, value: username, autoComplete: 'username', onChange: event => setUsername(event.target.value), placeholder: 'Web user' })),
          h(Field, { title: '密码' }, h('div', { className: 'password-control' }, h('input', { type: showPassword ? 'text' : 'password', value: password, autoComplete: 'current-password', onChange: event => setPassword(event.target.value), placeholder: 'Web password' }), h('button', { className: 'password-toggle', type: 'button', onClick: () => setShowPassword(previous => !previous), 'aria-label': showPassword ? '隐藏当前密码' : '显示当前密码', 'aria-pressed': showPassword }, showPassword ? '隐藏' : '显示'))),
          h('p', { className: 'login-error' }, error || ' '),
          h('button', { className: 'primary-button login-submit', disabled: busy || !username || !password, type: 'submit' }, busy ? '正在验证…' : '进入控制台'),
          h('div', { className: 'auth-note' }, 'Cookie 由后端 Session 自动分发，前端不会手动写入认证 Cookie。')
        )
      )
    );
  }

  function forwardingPort(target) {
    const value = String(target || '').trim();
    const match = value.match(/:(\d+)$/);
    if (!match) return 0;
    const port = Number(match[1]);
    return Number.isInteger(port) && port > 0 && port <= 65535 ? port : 0;
  }

  function Console() {
    const location = useLocation();
    const history = useHistory();
    const section = location.pathname === '/config' ? 'config' : 'overview';
    const [auth, setAuth] = React.useState(null);
    const [authError, setAuthError] = React.useState('');
    const [loginBusy, setLoginBusy] = React.useState(false);
    const [state, setState] = React.useState(null);
    const [error, setError] = React.useState('');
    const [form, setForm] = React.useState({ mode: 'client', index_address: '', relay_address: '', server_node_id: '', web_listen_address: '0.0.0.0:8088', security_profile: 'production', billing_key_file: '', identity_file: '' });
    const [mapping, setMapping] = React.useState({ protocol: 'tcp', listen: '127.0.0.1:18080', remote_port: 0 });
    const [port, setPort] = React.useState({ protocol: 'tcp', target: '127.0.0.1:8080' });
    const [editing, setEditing] = React.useState(null);
    const [dirty, setDirty] = React.useState(false);
    const dirtyRef = React.useRef(false);

    const markForm = patch => {
      dirtyRef.current = true;
      setDirty(true);
      setForm(previous => Object.assign({}, previous, patch));
    };
    const load = () => request('/api/status').then(snapshot => {
      setState(snapshot);
      if (!dirtyRef.current) setForm(Object.assign({}, snapshot.config));
      setError('');
    }).catch(err => {
      if (err.status === 401) setAuth(previous => previous ? Object.assign({}, previous, { authenticated: false }) : previous);
      setError(String(err.message || err));
    });

    React.useEffect(() => {
      request('/api/auth/status').then(status => {
        setAuth(status);
        if (!status.required || status.authenticated) load();
      }).catch(err => setAuthError(String(err.message || err)));
    }, []);

    React.useEffect(() => {
      if (!auth || (auth.required && !auth.authenticated)) return undefined;
      const timer = setInterval(load, 3000);
      return () => clearInterval(timer);
    }, [auth && auth.authenticated, auth && auth.required]);

    const login = (username, password) => {
      setLoginBusy(true);
      setAuthError('');
      request('/api/auth/login', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ username, password }) }).then(status => {
        setAuth({ required: true, authenticated: true, user: status.user });
        load();
      }).catch(err => setAuthError(String(err.message || err))).finally(() => setLoginBusy(false));
    };
    const logout = () => request('/api/auth/logout', { method: 'POST' }).finally(() => setAuth(previous => previous ? Object.assign({}, previous, { authenticated: false }) : previous));
    const save = () => request('/api/config', { method: 'PUT', headers: jsonHeaders, body: JSON.stringify(form) }).then(snapshot => {
      dirtyRef.current = false;
      setDirty(false);
      setState(snapshot);
      setError('');
    }).catch(err => setError(String(err.message || err)));
    const retry = () => request('/api/retry', { method: 'POST' }).then(snapshot => { setState(snapshot); setError(''); }).catch(err => setError(String(err.message || err)));
    const addMapping = () => request('/api/client/mappings', { method: 'POST', headers: jsonHeaders, body: JSON.stringify(mapping) }).then(() => { setMapping({ protocol: 'tcp', listen: '127.0.0.1:18080', remote_port: 0 }); load(); }).catch(err => setError(String(err.message || err)));
    const removeMapping = id => request('/api/client/mappings/' + encodeURIComponent(id), { method: 'DELETE' }).then(load).catch(err => setError(String(err.message || err)));
    const updateMapping = item => request('/api/client/mappings/' + encodeURIComponent(item.id), { method: 'PUT', headers: jsonHeaders, body: JSON.stringify(item) }).then(() => { setEditing(null); load(); }).catch(err => setError(String(err.message || err)));
    const addPort = () => {
      const portNumber = forwardingPort(port.target);
      if (!portNumber) {
        setError('转发端口必须填写 host:port 格式，例如 127.0.0.1:8080');
        return;
      }
      request('/api/server/ports', { method: 'POST', headers: jsonHeaders, body: JSON.stringify(Object.assign({}, port, { port: portNumber })) }).then(() => { setPort({ protocol: 'tcp', target: '127.0.0.1:8080' }); load(); }).catch(err => setError(String(err.message || err)));
    };
    const removePort = id => request('/api/server/ports/' + encodeURIComponent(id), { method: 'DELETE' }).then(load).catch(err => setError(String(err.message || err)));
    const updatePort = item => {
      const portNumber = forwardingPort(item.target);
      if (!portNumber) {
        setError('转发端口必须填写 host:port 格式，例如 127.0.0.1:8080');
        return;
      }
      request('/api/server/ports/' + encodeURIComponent(item.id), { method: 'PUT', headers: jsonHeaders, body: JSON.stringify(Object.assign({}, item, { port: portNumber })) }).then(() => { setEditing(null); load(); }).catch(err => setError(String(err.message || err)));
    };

    if (!auth) return h('div', { className: 'loading-screen' }, h('span', { className: 'spinner' }), '正在连接控制台…');
    if (auth.required && !auth.authenticated) return h(Login, { onLogin: login, error: authError, busy: loginBusy });

    const cfg = state ? state.config : form;
    const status = state ? state.status : 'loading';
    const statusGood = status === 'running';
    const statusGuide = status === 'waiting_for_configuration' ? h('section', { className: 'status-guide' }, h('div', { className: 'status-guide-icon' }, '!'), h('div', null, h('strong', null, '节点尚未启动：等待配置'), h('p', null, !cfg.mode ? '请先在“节点配置”选择 Client 或 Server。Server 需要配置转发端口；Client 需要填写目标 Server NodeID 和至少一个本地映射。' : cfg.security_profile === 'production' && !cfg.billing_key_file ? '当前是 production 安全档，请先填写 CA Web 导出的扣费密钥路径；然后补齐节点配置并点击“保存并启动”。' : cfg.mode === 'server' ? '请填写转发端口，然后点击“保存并启动”。收到远端流后，Server 会直接连接该目标。' : '请填写目标 Server NodeID 和本地映射，然后点击“保存并启动”。'), h('button', { className: 'secondary-button', type: 'button', onClick: () => history.push('/config') }, '去节点配置'))) : status === 'configuration_error' ? h('section', { className: 'status-guide error-guide' }, h('div', { className: 'status-guide-icon' }, '!'), h('div', null, h('strong', null, '配置校验失败'), h('p', null, state && state.last_error ? state.last_error : '请检查节点配置。'), h('button', { className: 'secondary-button', type: 'button', onClick: () => history.push('/config') }, '检查配置'))) : null;
    const selectProtocol = (value, setter) => h('select', { value: value || 'tcp', onChange: event => setter(event.target.value) }, h('option', { value: 'tcp' }, 'TCP'), h('option', { value: 'udp' }, 'UDP'));
    const mappingRows = (cfg.client_mappings || []).map(item => {
      if (editing && editing.kind === 'mapping' && editing.value.id === item.id) {
        const value = editing.value;
        const change = patch => setEditing({ kind: 'mapping', value: Object.assign({}, value, patch) });
        return h('div', { className: 'route-row editing', key: item.id }, h('div', { className: 'route-grid' }, h(Field, { title: '协议' }, selectProtocol(value.protocol, v => change({ protocol: v }))), h(Field, { title: '本地监听' }, h('input', { value: value.listen, onChange: event => change({ listen: event.target.value }) })), h(Field, { title: 'Server 路由键（可选）', hint: '留空或 0 时使用单一转发端口' }, h('input', { type: 'number', min: 0, max: 65535, value: value.remote_port, onChange: event => change({ remote_port: Number(event.target.value) }) }))), h('div', { className: 'row-actions' }, h('button', { className: 'primary-button small', type: 'button', onClick: () => updateMapping(value) }, '保存'), h('button', { className: 'quiet-button', type: 'button', onClick: () => setEditing(null) }, '取消')));
      }
      return h('div', { className: 'route-row', key: item.id }, h('div', null, h('strong', null, (item.protocol || 'tcp').toUpperCase() + ' ' + item.listen + ' → Server ' + (item.remote_port || '默认')), h('small', null, item.enabled ? 'ACTIVE' : 'DISABLED')), h('div', { className: 'row-actions' }, h('button', { className: 'quiet-button', type: 'button', onClick: () => setEditing({ kind: 'mapping', value: Object.assign({}, item) }) }, '编辑'), h('button', { className: 'danger-button', type: 'button', onClick: () => removeMapping(item.id) }, '删除')));
    });
    const portRows = (cfg.server_ports || []).map(item => {
      if (editing && editing.kind === 'port' && editing.value.id === item.id) {
        const value = editing.value;
        const change = patch => setEditing({ kind: 'port', value: Object.assign({}, value, patch) });
        return h('div', { className: 'route-row editing', key: item.id }, h('div', { className: 'route-grid forwarding-grid' }, h(Field, { title: '转发端口', hint: '收到远端流后直接连接，例如 127.0.0.1:18100' }, h('input', { value: value.target, onChange: event => change({ target: event.target.value }) })), h(Field, { title: '传输协议' }, selectProtocol(value.protocol, v => change({ protocol: v })))), h('div', { className: 'row-actions' }, h('button', { className: 'primary-button small', type: 'button', onClick: () => updatePort(value) }, '保存'), h('button', { className: 'quiet-button', type: 'button', onClick: () => setEditing(null) }, '取消')));
      }
      return h('div', { className: 'route-row', key: item.id }, h('div', null, h('strong', null, (item.protocol || 'tcp').toUpperCase() + ' · 转发端口 ' + item.target), h('small', null, item.enabled ? 'RECEIVE AND DISPATCH' : 'DISABLED')), h('div', { className: 'row-actions' }, h('button', { className: 'quiet-button', type: 'button', onClick: () => setEditing({ kind: 'port', value: Object.assign({}, item) }) }, '编辑'), h('button', { className: 'danger-button', type: 'button', onClick: () => removePort(item.id) }, '删除')));
    });

    return h('div', { className: 'app-shell' },
      h('aside', { className: 'sidebar' },
        h('a', { className: 'brand', href: '/overview' }, h('span', { className: 'brand-mark' }, h('i')), h('span', null, h('strong', null, 'fknat'), h('small', null, 'NATIVE TUNNEL CONTROL'))),
        h('nav', { className: 'nav' }, h(NavLink, { exact: true, to: '/overview', className: 'nav-item', activeClassName: 'active' }, h('span', null, '◈'), '运行概览'), h(NavLink, { exact: true, to: '/config', className: 'nav-item', activeClassName: 'active' }, h('span', null, '⌘'), '节点配置')),
        h('div', { className: 'sidebar-foot' }, h('div', { className: 'network-indicator' }, h('i'), statusGood ? '控制面在线' : '等待配置'), h('small', null, cfg.web_listen_address || '0.0.0.0:8088')),
        h('button', { className: 'text-button sidebar-logout', type: 'button', onClick: logout }, '退出登录')
      ),
      h('main', { className: 'main' },
        h('header', { className: 'topbar' }, h('div', null, h('p', { className: 'eyebrow' }, 'NODE CONTROL PLANE'), h('h1', null, section === 'overview' ? '运行概览' : '节点配置'), h('p', { className: 'topbar-subtitle' }, '通过安全会话管理本机 fknat 转发节点。')), h('div', { className: statusGood ? 'health-pill' : 'health-pill offline' }, h('i'), statusGood ? 'ONLINE' : String(status).toUpperCase())),
        error ? h('div', { className: 'toast error' }, error) : null,
        section === 'overview' ? h(React.Fragment, null,
          h('section', { className: 'stats-grid' }, h('article', { className: 'stat-card accent' }, h('p', null, '运行状态'), h('strong', null, status), h('small', null, cfg.mode || '未选择模式')), h('article', { className: 'stat-card' }, h('p', null, '节点角色'), h('strong', null, cfg.mode ? cfg.mode.toUpperCase() : '—'), h('small', null, cfg.server_node_id ? cfg.server_node_id.slice(0, 16) + '…' : '等待 NodeID')), h('article', { className: 'stat-card' }, h('p', null, '入口 Relay'), h('strong', null, cfg.relay_address || 'INDEX'), h('small', null, cfg.index_address || 'CA 自动发现'))),
          statusGuide,
          h('section', { className: 'panel' }, h('div', { className: 'panel-head' }, h('div', null, h('p', { className: 'kicker' }, 'LIVE CONFIGURATION'), h('h2', null, '连接参数')), h('span', { className: statusGood ? 'panel-tag success' : 'panel-tag' }, dirty ? 'UNSAVED' : 'SYNCED')), h('div', { className: 'config-summary' }, h('div', null, h('span', null, 'Web'), h('code', null, cfg.web_listen_address || '0.0.0.0:8088')), h('div', null, h('span', null, 'Index'), h('code', null, cfg.index_address || 'CA DISCOVERY')), h('div', null, h('span', null, 'Security'), h('code', null, cfg.security_profile || 'production')))),
          cfg.mode === 'client' ? h('section', { className: 'panel' }, h('div', { className: 'panel-head' }, h('div', null, h('p', { className: 'kicker' }, 'CLIENT ROUTES'), h('h2', null, '本地映射')), h('span', { className: 'panel-tag' }, (cfg.client_mappings || []).length + ' ROUTES')), h('div', { className: 'route-list' }, mappingRows.length ? mappingRows : h('div', { className: 'empty' }, '还没有本地映射'))) : h('section', { className: 'panel' }, h('div', { className: 'panel-head' }, h('div', null, h('p', { className: 'kicker' }, 'SERVER FORWARDING'), h('h2', null, '转发端口预览')), h('span', { className: 'panel-tag' }, (cfg.server_ports || []).length + ' PORTS')), h('div', { className: 'route-list' }, portRows.length ? portRows : h('div', { className: 'empty' }, '还没有配置转发端口')))
        ) : h(React.Fragment, null, statusGuide, h('section', { className: 'panel form-panel' },
          h('div', { className: 'panel-head' }, h('div', null, h('p', { className: 'kicker' }, 'RUNTIME PROFILE'), h('h2', null, '连接与运行配置')), h('button', { className: 'primary-button', type: 'button', onClick: save }, dirty || status === 'waiting_for_configuration' ? '保存并启动' : '保存配置')),
          h('div', { className: 'form-grid' }, h(Field, { title: '模式' }, h('select', { value: form.mode || 'client', onChange: event => markForm({ mode: event.target.value }) }, h('option', { value: 'client' }, 'Client'), h('option', { value: 'server' }, 'Server'))), h(Field, { title: 'Index 地址', hint: '留空时由 CA Web 自动发现' }, h('input', { value: form.index_address || '', placeholder: 'host:port', onChange: event => markForm({ index_address: event.target.value }) })), h(Field, { title: 'Relay 地址', hint: '可留空由 Index 选择' }, h('input', { value: form.relay_address || '', placeholder: 'host:port', onChange: event => markForm({ relay_address: event.target.value }) })), h(Field, { title: 'Web 监听地址', hint: '当前实例的监听地址，需通过启动参数修改' }, h('input', { disabled: true, value: form.web_listen_address || '0.0.0.0:8088', placeholder: '0.0.0.0:8088' })), h(Field, { title: '安全档' }, h('select', { value: form.security_profile || 'production', onChange: event => markForm({ security_profile: event.target.value }) }, h('option', { value: 'production' }, 'production'), h('option', { value: 'staging' }, 'staging'), h('option', { value: 'development' }, 'development'))), h(Field, { title: '扣费密钥路径', hint: '只保存路径，不上传密钥内容' }, h('input', { value: form.billing_key_file || '', placeholder: '/secure/billing-key.json', onChange: event => markForm({ billing_key_file: event.target.value }) })), h(Field, { title: '身份文件路径' }, h('input', { value: form.identity_file || '', placeholder: '留空自动生成', onChange: event => markForm({ identity_file: event.target.value }) })), form.mode === 'client' ? h(Field, { title: '目标 Server NodeID' }, h('input', { value: form.server_node_id || '', placeholder: '64 位 NodeID', onChange: event => markForm({ server_node_id: event.target.value }) })) : h(Field, { title: '默认转发端口', hint: '兼容单目标 Server 配置，例如 127.0.0.1:8080' }, h('input', { value: form.forward_target || '', placeholder: '127.0.0.1:8080', onChange: event => markForm({ forward_target: event.target.value }) }))),
          h('div', { className: 'form-actions' }, h('button', { className: 'secondary-button', type: 'button', onClick: retry }, '重试连接'), h('span', { className: 'form-note' }, state && state.last_error ? state.last_error : '配置会原子写入 JSON 文件；点击“保存并启动”后自动应用。')),
          form.mode === 'client' ? h('div', { className: 'subpanel' }, h('div', { className: 'panel-head compact' }, h('h3', null, 'Client 本地映射'), h('span', { className: 'panel-tag' }, 'TCP / UDP')), h('div', { className: 'route-grid' }, h(Field, { title: '协议' }, h('select', { value: mapping.protocol, onChange: event => setMapping(Object.assign({}, mapping, { protocol: event.target.value })) }, h('option', { value: 'tcp' }, 'TCP'), h('option', { value: 'udp' }, 'UDP'))), h(Field, { title: '本地监听' }, h('input', { value: mapping.listen, onChange: event => setMapping(Object.assign({}, mapping, { listen: event.target.value })) })), h(Field, { title: 'Server 路由键（可选）', hint: '留空或 0 时使用单一转发端口' }, h('input', { type: 'number', min: 0, max: 65535, value: mapping.remote_port, onChange: event => setMapping(Object.assign({}, mapping, { remote_port: Number(event.target.value) })) }))), h('button', { className: 'secondary-button', type: 'button', onClick: addMapping }, '添加映射')) : h(React.Fragment, null,
            h('div', { className: 'subpanel' }, h('div', { className: 'panel-head compact' }, h('div', null, h('h3', null, 'Server 转发端口'), h('p', { className: 'subpanel-note' }, '收到远端流后直接连接这里配置的目标，不会额外监听请求端口。')), h('span', { className: 'panel-tag' }, 'TCP / UDP')), h('div', { className: 'route-grid forwarding-grid' }, h(Field, { title: '转发端口', hint: '填写目标 host:port，例如 127.0.0.1:18100' }, h('input', { value: port.target, onChange: event => setPort(Object.assign({}, port, { target: event.target.value })) })), h(Field, { title: '传输协议' }, h('select', { value: port.protocol, onChange: event => setPort(Object.assign({}, port, { protocol: event.target.value })) }, h('option', { value: 'tcp' }, 'TCP'), h('option', { value: 'udp' }, 'UDP')))), h('div', { className: 'forwarding-action' }, h('button', { className: 'secondary-button', type: 'button', onClick: addPort }, '添加转发端口'))),
            h('section', { className: 'panel configured-routes-panel' }, h('div', { className: 'panel-head' }, h('div', null, h('p', { className: 'kicker' }, 'SERVER FORWARDING'), h('h2', null, '转发端口预览')), h('span', { className: 'panel-tag' }, (cfg.server_ports || []).length + ' PORTS')), h('div', { className: 'route-list' }, portRows.length ? portRows : h('div', { className: 'empty' }, '还没有配置转发端口。填写上方表单并点击“添加转发端口”后会显示在这里。')))
        ))
      )
    ));
  }

  function App() {
    const [auth, setAuth] = React.useState(null);
    const [authError, setAuthError] = React.useState('');
    const [loginBusy, setLoginBusy] = React.useState(false);
    const login = (username, password) => {
      setLoginBusy(true);
      setAuthError('');
      request('/api/auth/login', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ username, password }) }).then(status => setAuth({ required: true, authenticated: true, user: status.user })).catch(err => setAuthError(String(err.message || err))).finally(() => setLoginBusy(false));
    };
    React.useEffect(() => { request('/api/auth/status').then(setAuth).catch(err => setAuthError(String(err.message || err))); }, []);
    if (!auth) return h('div', { className: 'loading-screen' }, h('span', { className: 'spinner' }), '正在连接控制台…');
    if (auth.required && !auth.authenticated) return h(Login, { onLogin: login, error: authError, busy: loginBusy });
    return h(BrowserRouter, null, h(Switch, null, h(Route, { path: '/config', component: Console }), h(Route, { path: '/overview', component: Console }), h(Redirect, { to: '/overview' })));
  }

  ReactDOM.createRoot(document.getElementById('root')).render(h(App));
})();
