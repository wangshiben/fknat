package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/wangshiben/natP2pSDK/natclient"
)

func changeConfiguredNodeMode(ctx context.Context, previous, updated appConfig) error {
	if previous.Role == updated.Role || (updated.Role != roleClient && updated.Role != roleServer) {
		return nil
	}
	if updated.IdentityFile == "" {
		return errors.New("节点身份变更需要先配置 identity_file")
	}
	caURL := caURLForConfig(updated)
	if caURL == "" {
		return errors.New("节点身份变更需要连接 CA Web；开发安全档不能执行身份变更")
	}
	result, err := natclient.ChangeNodeMode(ctx, natclient.Config{Identity: updated.IdentityFile, CAURL: caURL}, string(updated.Role))
	if err != nil {
		return fmt.Errorf("节点身份变更挑战失败: %w", err)
	}
	if result.TargetRole != string(updated.Role) {
		return fmt.Errorf("CA 返回的目标角色 %q 与请求 %q 不一致", result.TargetRole, updated.Role)
	}
	return nil
}
