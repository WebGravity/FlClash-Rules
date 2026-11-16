# OpenClash 住宅链路自动发现

[查看覆写脚本](openclash_custom_overwrite.sh) · [下载原始脚本](https://raw.githubusercontent.com/WebGravity/FlClash-Rules/main/openclash/openclash_custom_overwrite.sh) · [住宅配置模板](residential.example.yaml)

为当前订阅中每个真实机场节点生成一条 SOCKS5 住宅链路，测试完整链路后自动选择。机场前置可以切换，最终住宅出口保持相同。此目录是 2026-11-16 实机覆写的公开版本；住宅账号独立保存于路由器，不包含在 GitHub 脚本中。

## 分流行为

| 流量 | 策略 |
| --- | --- |
| OpenAI / ChatGPT / Codex / Sora、Claude / Anthropic、X / Twitter / Grok 相关域名 | `住宅IP` |
| Bybit / Binance / OKX | `交易所-台韩日澳英澳门`，按节点名称匹配台湾、韩国、日本、澳大利亚、英国、澳门 |
| Google Play / Android 下载及配置中列出的 Google 共用 API/CDN | 机场自动选择组 |
| 中国大陆域名/IP、局域网、剪映及所列国内字节资源 | `DIRECT` |
| 其他流量 | `住宅IP` |

这是完整分流覆写：保留输入中的拒绝规则，重新生成其他 `rules`，并设为规则模式。请先阅读脚本里的域名清单，确认符合你的需求。交易所地区和测试参数沿用原方案，支持的地区不代表网站允许登录或交易。

## 自动发现与测速

```text
住宅IP
  └─ 住宅链路自动（url-test）
       ├─ 住宅IP-链式       → 真实机场节点 A
       ├─ 住宅链路｜节点 B  → 真实机场节点 B
       └─ 住宅链路｜节点 C  → 真实机场节点 C
            ↑ 每条都是同一个住宅 SOCKS5 出口，dialer-proxy 绑定对应机场节点
```

- 从输入 `proxies` 列表发现节点，过滤流量/到期提示、直连/拒绝节点和已有 `dialer-proxy` 的节点。不依赖固定机场名称或四节点白名单。
- 正常更新或切换订阅并应用配置时，重建候选。失败链路持续参与后续健康检查，恢复后可重新被选中。
- 测试地址为 `https://www.gstatic.com/generate_204`，预期 HTTP 204；每 300 秒检查，超时 8000ms，切换容差 100ms，`lazy: false`。
- 例如当前 220ms、最快 180ms，差距未超过 100ms 时会保留当前线路。不会每次都追随最低数字；测速与面板刷新也可能有时间差。
- 比较的是完整住宅链路，不是机场单独的延迟。延迟测试不等于下载带宽或目标网站业务测试。
- 没有住宅直连或机场裸出口回退；住宅链路全部失败时，住宅业务可能不可用。`empty-fallback: REJECT` 用于候选集合为空，不代表所有节点失效时立即拒绝。

## 支持范围

- OpenClash 的自定义覆写脚本，调用形式是 `sh openclash_custom_overwrite.sh 配置文件路径`。
- 路由器需要 Ruby 与 YAML 支持；不需要 `ruby-tempfile`。
- 使用 Mihomo 的 `socks5` + `dialer-proxy`，不使用 `relay`。实机链路逻辑在 OpenClash v0.48.002 / Mihomo alpha-gbc76c13 验证。
- 输入须包含展开的真实 `proxies`；不主动下载远端 `proxy-providers` 并展开。只有 provider、没有展开节点的订阅会报错。
- 只有属于当前输入的独立节点参与发现。所有生成链路复用同一住宅凭据，不更改原订阅源。
- `udp: true` 只是配置开关，本次验证覆盖 TCP/HTTPS，未验证住宅服务商的 UDP 转发。

## 首次安装

1. 在路由器备份现有 `/etc/openclash/custom/openclash_custom_overwrite.sh`，备份只保存在本地。
2. 将 [residential.example.yaml](residential.example.yaml) 复制为路由器的 `/etc/openclash/custom/residential.yaml`，把 `server`、`port`、`username`、`password` 填成自己的住宅 SOCKS5 信息。字符串保留引号，注意 YAML 转义。不要在 GitHub 网页中填写。
3. 在路由器执行 `chmod 600 /etc/openclash/custom/residential.yaml`，限制凭据文件权限。
4. 将公开脚本填入 OpenClash 的内置覆写编辑器并保存；或保存为 `/etc/openclash/custom/openclash_custom_overwrite.sh`。已有其他覆写时先备份，不要追加两份完整脚本。
5. 按插件正常流程应用配置。应用可能短暂重启核心，请在能够恢复管理连接时操作。
6. 确认插件日志包含 `[住宅链式覆写] 成功 v2026-11-16`，面板出现 `住宅IP`、`住宅链路自动` 和完整链路候选，再检查 GPT/X 规则命中、最终出口与住宅地址一致、国内直连以及交易所分组。

**公开版首次替换旧版前，必须准备好本地 `residential.yaml`。** 旧版脚本内的凭据不会自动迁移。发布到 GitHub 本身不会修改已运行的路由器。

更新本脚本时保留本地 `residential.yaml` 即可。也可通过环境变量 `RESIDENTIAL_CONFIG` 指定其他私有文件路径。`AIRPORT_AUTO_GROUP` 可指定已有机场 `url-test` 组，主要供 Google Play 分流使用；为空时自动识别，无法唯一识别时从真实节点创建 `机场自动选择`。

## 失败与恢复

- 配置或凭据检查失败时，脚本非零退出，不覆盖传入配置文件。错误日志不包含凭据。
- **保留输入文件不等于保留住宅分流**：若输入是原始订阅，OpenClash 后续是否继续加载取决于插件流程。看到覆写失败时，先检查运行配置；不可假定仍走住宅。
- 回退时恢复本地备份的覆写，再按插件流程应用，并验证出口。勿使用住宅端点已过期的旧备份。
- 原始节点有延迟而住宅链路显示失败，只能说明串联路径不通，可能涉及目标端口限制、来源限制或网络路径；不能仅凭协议名称判定永久不兼容。

## 本地验证

需要 Python 3、Ruby 和 YAML；测试仅使用文档保留地址与虚拟凭据。

```sh
python3 openclash/tests/test_overwrite.py
```

可选核心语法检查：

```sh
MIHOMO_BIN=/path/to/mihomo python3 openclash/tests/test_overwrite.py
```

合成配置的离线核心检查会去掉需要下载 Geo 数据的规则；实际部署还需验证设备已有的 Geo 数据与目标站点。

参考：[Mihomo 自动选择](https://wiki.metacubex.one/config/proxy-groups/url-test/) · [dialer-proxy](https://wiki.metacubex.one/config/proxies/dialer-proxy/)
