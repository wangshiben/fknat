export default function StatusGuide({ status, config, lastError, onGoToConfig }) {
  if (status === 'waiting_for_configuration') {
    const message = !config.mode
      ? '请先在“节点配置”选择 Client 或 Server。Server 需要配置转发端口；Client 需要填写目标 Server NodeID 和至少一个本地映射。'
      : config.security_profile === 'production' && !config.billing_key_file
        ? '当前是 production 安全档，请先填写 CA Web 导出的扣费密钥路径；然后补齐节点配置并点击“保存并启动”。'
        : config.mode === 'server'
          ? '请填写转发端口，然后点击“保存并启动”。收到远端流后，Server 会直接连接该目标。'
          : '请填写目标 Server NodeID 和本地映射，然后点击“保存并启动”。';
    return (
      <section className="status-guide">
        <div className="status-guide-icon">!</div>
        <div><strong>节点尚未启动：等待配置</strong><p>{message}</p><button className="secondary-button" type="button" onClick={onGoToConfig}>去节点配置</button></div>
      </section>
    );
  }
  if (status === 'configuration_error') {
    return (
      <section className="status-guide error-guide">
        <div className="status-guide-icon">!</div>
        <div><strong>配置校验失败</strong><p>{lastError || '请检查节点配置。'}</p><button className="secondary-button" type="button" onClick={onGoToConfig}>检查配置</button></div>
      </section>
    );
  }
  return null;
}
