# Linux CLI 配置 cc-switch 和 Claude Code

本文记录如何在 Linux 命令行中安装 `cc-switch`、配置 Claude provider，并安装测试 Claude Code CLI。

## 1. 准备 `.env`

配置文件放在：

```bash
/home/sy/vpn/.env
```

格式如下：

```bash
ENDPOINT=https://example.com/apps/anthropic
API_KEY=sk-xxxx
MODEL=qwen3.6-plus
```

其中：

- `ENDPOINT` 是 Anthropic/Claude 协议入口。
- `API_KEY` 是访问密钥。
- `MODEL` 是默认模型名。

注意：如果 endpoint 类似 `.../apps/anthropic`，它通常适合 Claude/Anthropic 协议，不适合作为 Codex/OpenAI Responses provider。

## 2. 安装 cc-switch

```bash
curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash
```

确认安装成功：

```bash
cc-switch --version
```

安装位置通常是：

```bash
~/.local/bin/cc-switch
```

如果命令找不到，确认 `~/.local/bin` 在 `PATH` 中：

```bash
echo "$PATH"
```

## 3. 配置 Claude provider

先备份当前 cc-switch 配置：

```bash
cc-switch config backup
```

用 `.env` 写入 `vpn` provider：

```bash
python3 - <<'PY'
import json, sqlite3, time
from pathlib import Path

env_path = Path('/home/sy/vpn/.env')
values = {}
for raw in env_path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    values[k.strip()] = v.strip().strip('"').strip("'")

missing = [k for k in ('ENDPOINT', 'API_KEY', 'MODEL') if not values.get(k)]
if missing:
    raise SystemExit(f"Missing required keys in {env_path}: {', '.join(missing)}")

settings_config = {
    'env': {
        'ANTHROPIC_AUTH_TOKEN': values['API_KEY'].strip(),
        'ANTHROPIC_BASE_URL': values['ENDPOINT'].strip(),
        'ANTHROPIC_MODEL': values['MODEL'].strip(),
    }
}

now = int(time.time())
conn = sqlite3.connect('/home/sy/.cc-switch/cc-switch.db')
try:
    conn.execute('BEGIN')
    conn.execute("UPDATE providers SET is_current = 0 WHERE app_type = 'claude'")
    conn.execute(
        '''INSERT INTO providers
           (id, app_type, name, settings_config, website_url, category, created_at, sort_index,
            notes, icon, icon_color, meta, is_current, in_failover_queue, cost_multiplier,
            limit_daily_usd, limit_monthly_usd, provider_type)
           VALUES (?, 'claude', ?, ?, ?, NULL, ?, ?, ?, NULL, NULL, '{}', 1, 0, '1.0', NULL, NULL, NULL)
           ON CONFLICT(id, app_type) DO UPDATE SET
             name=excluded.name,
             settings_config=excluded.settings_config,
             website_url=excluded.website_url,
             created_at=COALESCE(providers.created_at, excluded.created_at),
             sort_index=excluded.sort_index,
             notes=excluded.notes,
             meta=excluded.meta,
             is_current=1,
             in_failover_queue=0,
             cost_multiplier='1.0',
             provider_type=NULL''',
        ('vpn', 'VPN Provider', json.dumps(settings_config, ensure_ascii=False), values['ENDPOINT'].strip(), now, 0, 'Imported from /home/sy/vpn/.env')
    )
    conn.execute("DELETE FROM provider_endpoints WHERE provider_id = 'vpn' AND app_type = 'claude'")
    conn.execute(
        "INSERT INTO provider_endpoints(provider_id, app_type, url, added_at) VALUES ('vpn', 'claude', ?, ?)",
        (values['ENDPOINT'].strip(), now),
    )
    conn.commit()
finally:
    conn.close()

print('Configured claude provider: vpn')
PY
```

切换到这个 provider，并同步到 Claude Code 配置：

```bash
cc-switch --app claude provider switch vpn
```

查看当前配置：

```bash
cc-switch --app claude provider current
```

## 4. 测试 provider

流式健康检查：

```bash
cc-switch --app claude provider stream-check vpn
```

成功时应看到类似：

```text
Status:  operational
HTTP:    200
Message: Check succeeded
```

也可以检查本地 CLI 工具状态：

```bash
cc-switch env tools
```

## 5. 安装 Claude Code CLI

`cc-switch` 只管理配置，不会自动安装 `claude` 命令。需要单独安装 Claude Code CLI。

Claude Code 当前 npm 包要求 Node.js `>=18`。如果系统 Node 太旧，可以安装用户级 Node LTS 到 `~/.local/opt`：

```bash
base=https://nodejs.org/dist/latest-v22.x
file=$(curl -fsSL "$base/SHASUMS256.txt" | awk '/node-v22.*-linux-x64.tar.xz$/ {print $2; exit}')

mkdir -p ~/.local/opt /tmp/node-install
cd /tmp/node-install
curl -fLO "$base/$file"
tar -xJf "$file" -C ~/.local/opt

version=${file%-linux-x64.tar.xz}
ln -sfn "$HOME/.local/opt/$version-linux-x64" "$HOME/.local/opt/node-v22"
ln -sfn "$HOME/.local/opt/node-v22/bin/node" "$HOME/.local/bin/node"
ln -sfn "$HOME/.local/opt/node-v22/bin/npm" "$HOME/.local/bin/npm"
ln -sfn "$HOME/.local/opt/node-v22/bin/npx" "$HOME/.local/bin/npx"

hash -r
node --version
npm --version
```

设置 npm 全局安装目录：

```bash
npm config set prefix ~/.local
```

安装 Claude Code：

```bash
npm install -g @anthropic-ai/claude-code
```

确认命令可用：

```bash
command -v claude
claude --version
```

## 6. 端到端测试

运行一个最小非交互请求：

```bash
claude -p '只回复 OK' --permission-mode bypassPermissions
```

如果返回：

```text
OK
```

说明 Claude Code CLI 已安装成功，并且已经使用 `cc-switch` 配置好的 provider 走通接口。

## 7. 常见问题

### 输入 `claude` 提示命令不存在

说明只配置了 provider，但还没有安装 Claude Code CLI。执行：

```bash
npm install -g @anthropic-ai/claude-code
```

如果 Node 版本低于 18，先按第 5 节安装新版 Node。

### `cc-switch env tools` 显示 Claude not installed

这也是 Claude Code CLI 未安装，或 `~/.local/bin` 不在 `PATH` 中。

检查：

```bash
echo "$PATH"
ls -l ~/.local/bin/claude
```

### Codex provider 测试失败

如果 endpoint 是 `.../apps/anthropic`，不要配置成 Codex provider。Codex 通常需要 OpenAI-compatible/Responses 协议入口，例如可响应 `/v1/models` 或 Responses API 的 endpoint。

### 切换后没有生效

切换 provider 后，重启对应 CLI 客户端：

```bash
cc-switch --app claude provider switch vpn
claude
```