import { useEffect, useState } from 'react';
import { BrowserRouter, Redirect, Route, Switch } from 'react-router-dom';
import { jsonHeaders, request } from './api/client.js';
import LoginPage from './components/LoginPage.jsx';
import ConsolePage from './pages/ConsolePage.jsx';

export default function App() {
  const [auth, setAuth] = useState(null);
  const [authError, setAuthError] = useState('');
  const [loginBusy, setLoginBusy] = useState(false);

  useEffect(() => { request('/api/auth/status').then(setAuth).catch(err => setAuthError(String(err.message || err))); }, []);
  const login = (username, password) => {
    setLoginBusy(true); setAuthError('');
    request('/api/auth/login', { method: 'POST', headers: jsonHeaders, body: JSON.stringify({ username, password }) }).then(status => setAuth({ required: true, authenticated: true, user: status.user })).catch(err => setAuthError(String(err.message || err))).finally(() => setLoginBusy(false));
  };
  if (!auth) return <div className="loading-screen"><span className="spinner" />正在连接控制台…</div>;
  if (auth.required && !auth.authenticated) return <LoginPage onLogin={login} error={authError} busy={loginBusy} />;
  return <BrowserRouter><Switch><Route path="/config" component={ConsolePage} /><Route path="/overview" component={ConsolePage} /><Redirect to="/overview" /></Switch></BrowserRouter>;
}
