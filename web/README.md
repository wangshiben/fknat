# fknat Web 前端

`src/` 保存前端源码，使用 Vite + React JSX 构建：

- `src/main.jsx`：前端入口
- `src/App.jsx`：认证和路由入口
- `src/pages/`：概览页、配置页和控制台状态逻辑
- `src/components/`：表单、导航、状态提示和路由编辑组件
- `src/api/client.js`：Web API 请求封装
- `src/app.css`：控制台样式
- `src/index.html`：Vite HTML 入口

运行 `npm install` 后使用 `npm run build` 生成 `dist/`。`dist/` 是随 Go 二进制嵌入的发布资源；Vite 会把 React 运行时打入 `app.js`，不依赖公网 CDN。
