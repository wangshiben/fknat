import { useState } from 'react';
import Field from './Field.jsx';

export default function LoginPage({ onLogin, error, busy }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);

  const submit = event => {
    event.preventDefault();
    onLogin(username, password);
  };

  return (
    <div className="login-layer">
      <div className="auth-layout">
        <section className="auth-story">
          <a className="brand" href="/overview">
            <span className="brand-mark"><i /></span>
            <span><strong>fknat</strong><small>NATIVE TUNNEL CONTROL</small></span>
          </a>
          <div className="auth-copy">
            <p className="kicker">SECURE NODE CONSOLE</p>
            <h1>让每条连接，清晰可控。</h1>
            <p>管理 Node、Relay、端口映射和运行状态。控制台会通过后端会话保护配置与运行操作。</p>
          </div>
          <div className="auth-features">
            <div className="auth-feature"><span>01</span><div><strong>Session protected</strong><small>登录状态由 QuicFrameWork Session 管理</small></div></div>
            <div className="auth-feature"><span>02</span><div><strong>Route aware</strong><small>每条映射都带有明确的转发端口</small></div></div>
            <div className="auth-feature"><span>03</span><div><strong>Production ready</strong><small>配置原子写入，状态实时刷新</small></div></div>
          </div>
        </section>
        <form className="login-card" onSubmit={submit}>
          <p className="kicker">WEB ACCESS</p>
          <h2>登录控制台</h2>
          <p className="login-lead">输入启动参数中配置的 Web 用户名和密码。</p>
          <Field title="用户名">
            <input autoFocus value={username} autoComplete="username" onChange={event => setUsername(event.target.value)} placeholder="Web user" />
          </Field>
          <Field title="密码">
            <div className="password-control">
              <input type={showPassword ? 'text' : 'password'} value={password} autoComplete="current-password" onChange={event => setPassword(event.target.value)} placeholder="Web password" />
              <button className="password-toggle" type="button" onClick={() => setShowPassword(previous => !previous)} aria-label={showPassword ? '隐藏当前密码' : '显示当前密码'} aria-pressed={showPassword}>{showPassword ? '隐藏' : '显示'}</button>
            </div>
          </Field>
          <p className="login-error">{error || ' '}</p>
          <button className="primary-button login-submit" disabled={busy || !username || !password} type="submit">{busy ? '正在验证…' : '进入控制台'}</button>
          <div className="auth-note">Cookie 由后端 Session 自动分发，前端不会手动写入认证 Cookie。</div>
        </form>
      </div>
    </div>
  );
}
