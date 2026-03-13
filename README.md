# Open WebUI + LiteLLM + Amazon Bedrock 企业部署最佳实践

一键部署企业级 AI 聊天平台：Open WebUI 提供聊天界面 + SSO 登录，LiteLLM 提供 API 网关 + 按用户计费/限额，Amazon Bedrock 提供 Claude 等模型服务。

## 架构

```
员工浏览器
    │
    │ ① SSO 登录
    ▼
┌──────────────┐        ┌──────────────────┐        ┌──────────────┐
│  企业 SSO     │◄──────►│  Open WebUI       │──────►│  LiteLLM      │──────► Amazon Bedrock
│  (Okta/AD等)  │  OIDC  │  聊天界面         │ API Key│  API 网关     │ SigV4  (Claude 等)
└──────────────┘        └──────────────────┘        └──────────────┘
                                                          │
                                                    ┌─────┴─────┐
                                                    │ PostgreSQL │
                                                    │ 用量/计费   │
                                                    └───────────┘
```

## 核心功能

| 功能 | 说明 | 免费？ |
|:--|:--|:--|
| SSO 登录 | 员工用企业账号登录，无需 API Key | ✅ |
| 多模型支持 | Claude Sonnet / Haiku 等，可扩展 | ✅ |
| 按用户计费 | 自动追踪每个用户的 token 用量和费用 | ✅ |
| 预算限额 | 按用户/团队设月预算，超额自动拒绝 | ✅ |
| 限速控制 | 按用户设 RPM/TPM 限制 | ✅ |
| 聊天记录 | 每个用户独立的聊天历史 | ✅ |
| 跨账号调用 | 支持 AssumeRole 跨 AWS 账号调 Bedrock | ✅ |

## 快速开始

### 前提条件

- Docker + Docker Compose
- AWS 账号，已开通 Bedrock 模型访问
- AWS Access Key（有 Bedrock 调用权限）

### 1. 克隆项目

```bash
git clone https://github.com/NEOSUN100/bedrock-litellm-openwebui.git
cd bedrock-litellm-openwebui
```

### 2. 配置环境变量

```bash
cp .env.example .env
```

编辑 `.env`，填入：

```bash
# 必填
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
LITELLM_MASTER_KEY=sk-your-random-string    # 管理员密钥，随机生成
POSTGRES_PASSWORD=your-strong-password

# 可选
AWS_DEFAULT_REGION=us-east-1                 # Bedrock 所在区域
```

### 3. 启动服务

```bash
docker compose up -d
```

等待约 30 秒，三个服务启动完成。

### 4. 验证

```bash
bash test.sh
```

### 5. 访问

| 服务 | 地址 | 用途 |
|:--|:--|:--|
| Open WebUI | http://localhost:3000 | 员工聊天界面 |
| LiteLLM UI | http://localhost:4000/ui | 管理员后台（用 LITELLM_MASTER_KEY 登录） |

首次访问 Open WebUI 需要注册一个管理员账号（第一个注册的用户自动成为管理员）。

## 配置说明

### 模型配置

编辑 `litellm-config.yaml` 添加或修改模型：

```yaml
model_list:
  - model_name: claude-sonnet          # 用户看到的模型名
    litellm_params:
      model: bedrock/us.anthropic.claude-3-5-sonnet-20241022-v2:0  # Global Endpoint
      aws_region_name: us-east-1
```

模型 ID 使用 `us.` 前缀（Global Endpoint），比 Geo Endpoint 便宜 10%，且支持跨区域自动路由。

### 跨账号调用

如果 Bedrock 在另一个 AWS 账号（B 账号），在 `litellm-config.yaml` 中取消注释并配置：

```yaml
model_list:
  - model_name: claude-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-3-5-sonnet-20241022-v2:0
      aws_region_name: ap-northeast-1
      aws_role_name: arn:aws:iam::<B账号ID>:role/BedrockCrossAccountRole
      aws_session_name: litellm-cross-account
```

B 账号需要创建 IAM Role 并配置信任策略，详见 [跨账号配置](#跨账号-iam-配置)。

### SSO 配置

在 `docker-compose.yaml` 的 openwebui 服务中取消注释 SSO 相关环境变量，或在 `.env` 中配置：

```bash
OAUTH_CLIENT_ID=your-client-id
OAUTH_CLIENT_SECRET=your-client-secret
OPENID_PROVIDER_URL=https://your-idp/.well-known/openid-configuration
```

SSO 回调地址：`https://<your-openwebui-domain>/oauth/oidc/callback`

支持：Okta、Azure AD、Google Workspace、Keycloak 等任何 OIDC 提供商。

### 用户预算管理

```bash
MASTER_KEY="your-litellm-master-key"
LITELLM_URL="http://localhost:4000"

# 创建预算模板：每月 $50，每分钟最多 10 次请求
curl -X POST "$LITELLM_URL/budget/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"budget_id":"standard","max_budget":50,"budget_duration":"30d","rpm_limit":10}'

# 给用户绑定预算
curl -X POST "$LITELLM_URL/customer/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"alice@company.com","budget_id":"standard"}'

# 查看用户用量
curl "$LITELLM_URL/customer/info?end_user_id=alice@company.com" \
  -H "Authorization: Bearer $MASTER_KEY"
```

设置全局默认预算（所有用户自动适用），在 `litellm-config.yaml` 中加：

```yaml
litellm_settings:
  max_end_user_budget_id: "standard"
```

## 跨账号 IAM 配置

### B 账号：创建 Bedrock 访问 Role

权限策略：
```json
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        "Resource": "*"
    }]
}
```

信任策略：
```json
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"AWS": "arn:aws:iam::<A账号ID>:role/<LiteLLM的Role>"},
        "Action": "sts:AssumeRole"
    }]
}
```

### A 账号：LiteLLM 的 Role 需要 AssumeRole 权限

```json
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "sts:AssumeRole",
        "Resource": "arn:aws:iam::<B账号ID>:role/BedrockCrossAccountRole"
    }]
}
```

## POC 验证结果

以下为实际测试结果（2026-03-13）：

| 验证项 | 结果 |
|:--|:--|
| LiteLLM 启动 + DB 连接 | ✅ 通过 |
| 模型注册 (sonnet + haiku) | ✅ 通过 |
| Bedrock Global Endpoint 调用 | ✅ 通过 |
| 多用户区分 (alice/bob/charlie) | ✅ 通过 |
| 按用户统计 spend | ✅ 通过 (alice: $0.000218) |
| 预算限额 (charlie $0 被拒绝) | ✅ 通过 (ExceededBudget) |
| Open WebUI 启动 + 连接 LiteLLM | ✅ 通过 |

预算拦截实际返回：
```
ExceededBudget: End User=charlie@company.com over budget. Spend=9.04e-05, Budget=0.0
```

## 各组件职责

| 组件 | 面向谁 | 职责 |
|:--|:--|:--|
| Open WebUI | 员工 | 聊天界面、SSO 登录、聊天记录管理 |
| LiteLLM | 管理员 | API 网关、模型路由、用量统计、预算控制 |
| PostgreSQL | 系统 | 存储用户用量、预算、Key 等数据 |
| Bedrock | 系统 | AI 模型推理（Claude 等） |

## SSO 说明

- **SSO 只需配在 Open WebUI 上**，员工通过 SSO 登录聊天
- **LiteLLM 不需要配 SSO**，Open WebUI 到 LiteLLM 用 API Key 内网通信
- 员工不需要任何 API Key，全程无感知
- LiteLLM 通过 Open WebUI 转发的 `X-OpenWebUI-User-Email` Header 识别用户

## 参考文档

- [Open WebUI 文档](https://docs.openwebui.com)
- [LiteLLM 文档](https://docs.litellm.ai)
- [LiteLLM 按用户计费](https://docs.litellm.ai/docs/proxy/customers)
- [LiteLLM Bedrock 配置](https://docs.litellm.ai/docs/pass_through/bedrock)
- [Bedrock 跨账号访问](https://repost.aws/knowledge-center/bedrock-api-cross-account-access)
- [Bedrock Cross-Region Inference](https://aws.amazon.com/blogs/machine-learning/enable-amazon-bedrock-cross-region-inference-in-multi-account-environments/)

## License

MIT
