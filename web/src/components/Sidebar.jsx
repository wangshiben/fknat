import { NavLink } from 'react-router-dom';
import Brand from './Brand.jsx';

export default function Sidebar({ statusGood, webAddress, onLogout }) {
  return (
    <aside className="sidebar">
      <Brand />
      <nav className="nav">
        <NavLink exact to="/overview" className="nav-item" activeClassName="active"><span>◈</span>运行概览</NavLink>
        <NavLink exact to="/config" className="nav-item" activeClassName="active"><span>⌘</span>节点配置</NavLink>
      </nav>
      <div className="sidebar-foot"><div className="network-indicator"><i />{statusGood ? '控制面在线' : '等待配置'}</div><small>{webAddress || '0.0.0.0:8088'}</small></div>
      <button className="text-button sidebar-logout" type="button" onClick={onLogout}>退出登录</button>
    </aside>
  );
}
