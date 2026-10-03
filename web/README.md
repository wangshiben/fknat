# fknat Web 前端

`src/` 保存前端源码：

- `src/app.js`：React 管理控制台和 React Router 页面逻辑
- `src/app.css`：控制台样式
- `src/index.html`：前端入口

`dist/` 是随 Go 二进制嵌入的发布资源。修改 `src/` 后，需要同步更新对应的 `dist/` 文件；`dist/` 中的 React、ReactDOM 和 React Router 文件是固定版本的浏览器运行时依赖。
