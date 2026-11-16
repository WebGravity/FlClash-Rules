#!/bin/sh
# OpenClash 自定义覆写 v2026-11-16：订阅更新时自动重建住宅链式与分流。
# 国内直连；交易所台韩日澳英澳门；Google Play 机场自动；其余国外住宅出口。
# 如有多个自动组且无法识别总自动组，在下面填入机场原有组的完整名称。
AIRPORT_AUTO_GROUP="${AIRPORT_AUTO_GROUP:-}"
RESIDENTIAL_CONFIG="${RESIDENTIAL_CONFIG:-/etc/openclash/custom/residential.yaml}"
OVERWRITE_LOG="${OVERWRITE_LOG:-/tmp/openclash.log}"
export AIRPORT_AUTO_GROUP RESIDENTIAL_CONFIG OVERWRITE_LOG
CONFIG_FILE="$1"
[ -f "$CONFIG_FILE" ] || { echo "[住宅链式覆写] 缺少输入配置文件" >&2; exit 1; }

ruby -EUTF-8:UTF-8 -ryaml -e '
path = ARGV[0]
begin
  begin
    data = YAML.load_file(path, aliases: true)
  rescue ArgumentError
    data = YAML.load_file(path)
  end
  raise "配置不是 YAML 对象" unless data.is_a?(Hash)

  residential_group = "住宅IP"
  residential_exit = "住宅IP-链式"
  exchange_group = "交易所-台韩日澳英澳门"
  managed = [residential_group, residential_exit, "住宅IP-出口",
    "住宅链式前置", "住宅链式前置自动", exchange_group,
    "OpenAI-日本固定", "交易所-台日韓新", "交易所-台韩日新", "币安-台韩日", "Bybit-台韩日"]
  generated = Array(data["proxies"]).map { |p| p.is_a?(Hash) ? p["name"] : nil }.compact.select { |n| n.start_with?("住宅链路｜") }; managed += generated + ["住宅链路自动", "机场自动选择"]
  proxies = Array(data["proxies"]).select { |p| p.is_a?(Hash) && !managed.include?(p["name"]) }
  groups = Array(data["proxy-groups"]).select { |g| g.is_a?(Hash) && !managed.include?(g["name"]) }
  providers = data["proxy-providers"].is_a?(Hash) ? data["proxy-providers"] : {}
  proxy_map = proxies.each_with_object({}) { |p, h| h[p["name"]] = p }
  group_map = groups.each_with_object({}) { |g, h| h[g["name"]] = g }
  names = proxies.map { |p| p["name"] } + groups.map { |g| g["name"] }
  raise "节点或策略组名称重复" unless names.uniq.size == names.size

  autos = groups.select { |g| g["type"] == "url-test" }
  requested = ENV["AIRPORT_AUTO_GROUP"].to_s.strip
  if requested.empty?
    general_names = ["自动选择", "自动优选", "机场自动", "机场自动选择", "全自动", "AUTO", "AUTOMATIC", "URLTEST"]
    matches = autos.select do |g|
      normalized = g["name"].to_s.gsub(/[^\p{Han}a-zA-Z0-9]/, "").upcase
      general_names.include?(normalized)
    end
    chosen = matches.size == 1 ? matches.first : (matches.empty? && autos.size == 1 ? autos.first : nil)
  else
    chosen = autos.find { |g| g["name"] == requested }
  end
  if !chosen && requested.empty?; real = proxies.select { |p| !p["server"].to_s.empty? && p["dialer-proxy"].to_s.empty? && !%w[direct reject dns pass compatible].include?(p["type"].to_s.downcase) && !p["name"].to_s.match?(/剩余|到期|重置|套餐|官网|订阅|Traffic|Expire|Reset|Quota/i) }.map { |p| p["name"] }; raise "未发现机场节点" if real.empty?; chosen = {"name" => "机场自动选择", "type" => "url-test", "proxies" => real, "url" => "https://www.gstatic.com/generate_204", "interval" => 300, "lazy" => false}; groups << chosen; group_map[chosen["name"]] = chosen; end
  raise "无法唯一识别机场自带的自动选择组；请填写 AIRPORT_AUTO_GROUP（必须为 url-test 组）" unless chosen
  auto_name = chosen["name"]

  # 清理旧覆写插入的住宅/固定日本组引用，不向机场选择器反向插入住宅出口。
  groups.each do |g|
    if g["proxies"].is_a?(Array)
      g["proxies"] = g["proxies"].reject { |n| managed.include?(n) }.uniq
    end
    g.delete("default-selected") if managed.include?(g["default-selected"])
    g.delete("empty-fallback") if managed.include?(g["empty-fallback"])
  end

  # 机场订阅中的流量/到期提示不参与前置测速。
  notice = /(?:剩余流量|套餐到期|到期时间|流量重置|Traffic|Expire)/i
  if chosen["proxies"].is_a?(Array)
    chosen["proxies"] = chosen["proxies"].reject { |n| n.match?(notice) }
  end

  # 检查自动组的显式子组、节点 dialer-proxy 和 provider override，阻止回环和直连前置。
  visiting = []
  checked = []
  check = nil
  check = lambda do |name|
    raise "机场自动组存在循环引用" if visiting.include?(name)
    raise "机场自动组包含直连、拒绝或住宅出口，不能作为前置" if managed.include?(name) || ["DIRECT", "COMPATIBLE", "REJECT", "REJECT-DROP", "PASS"].include?(name)
    return if checked.include?(name)
    visiting << name
    if (g = group_map[name])
      refs = Array(g["proxies"])
      if g["include-all"] == true || g["include-all-proxies"] == true
        # 避免新增的住宅节点被 include-all 收回前置形成回环。
        exclusion = "^住宅IP-链式$"
        existing = g["exclude-filter"].to_s
        g["exclude-filter"] = existing.empty? ? exclusion : "(?:#{existing})|#{exclusion}" unless existing.include?(exclusion)
        refs += proxy_map.keys
      end
      use = Array(g["use"])
      use = providers.keys if g["include-all"] == true || g["include-all-providers"] == true
      raise "机场自动组或其子组为空" if refs.empty? && use.empty?
      refs.uniq.each { |ref| check.call(ref) }
      use.each do |provider_name|
        provider = providers[provider_name]
        raise "自动组引用的 provider 不存在" unless provider.is_a?(Hash)
        override = provider["override"]
        check.call(override["dialer-proxy"]) if override.is_a?(Hash) && override["dialer-proxy"]
        Array(provider["payload"]).each do |p|
          raise "provider 内含住宅节点" if p.is_a?(Hash) && managed.include?(p["name"])
          check.call(p["dialer-proxy"]) if p.is_a?(Hash) && p["dialer-proxy"]
        end
      end
      # provider 暂无可用节点时不允许回退为直连。
      g["empty-fallback"] = "REJECT"
    elsif (p = proxy_map[name])
      raise "自动组候选不是机场代理节点" if ["direct", "reject", "dns", "pass", "compatible"].include?(p["type"].to_s.downcase)
      check.call(p["dialer-proxy"]) if p["dialer-proxy"]
    else
      raise "自动组引用了未定义的节点或策略组"
    end
    visiting.pop
    checked << name
  end
  managed.delete("机场自动选择"); check.call(auto_name)

  # 私有住宅凭据只从路由器本地读取，不写进公开脚本或订阅地址。
  private_path = ENV.fetch("RESIDENTIAL_CONFIG")
  raise "缺少本地住宅配置；请先填写 residential.yaml" unless File.file?(private_path)
  private_config = YAML.load_file(private_path)
  raise "住宅配置必须是 YAML 对象" unless private_config.is_a?(Hash)
  %w[server username password].each do |key|
    value = private_config[key]
    raise "住宅配置必填项缺失或仍为占位符" unless value.is_a?(String) && !value.strip.empty? && !value.include?("CHANGE_ME")
  end
  port = Integer(private_config["port"].to_s, 10) rescue nil
  raise "住宅端口必须为 1–65535 的整数" unless port && (1..65535).include?(port)
  udp = private_config.fetch("udp", true)
  raise "udp 必须为 true 或 false" unless [true, false].include?(udp)
  residential_base = {
    "type" => "socks5", "server" => private_config["server"], "port" => port,
    "username" => private_config["username"], "password" => private_config["password"], "udp" => udp
  }
  residential_base["name"] = residential_exit
  # Complete-chain health checks; every candidate has the same SOCKS5 exit.
  # No country/name allowlist. Ignore quota labels and pre-chained nodes.
  fronts = proxy_map.values.select do |p|
    p["name"].is_a?(String) && !p["name"].match?(/剩余|到期|重置|套餐|官网|订阅|Traffic|Expire|Reset|Quota/i) &&
      !p["server"].to_s.empty? && p["dialer-proxy"].to_s.empty? &&
      !%w[direct reject dns pass compatible].include?(p["type"].to_s.downcase)
  end
  raise "未发现可独立拨号的机场节点；请使用包含展开节点的订阅配置" if fronts.empty?
  fronts.sort_by! { |p| p["name"] }
  # Keep the original name a SOCKS5 node, not a relay/group.
  residential_base["dialer-proxy"] = fronts.first["name"]
  chain_names = [residential_exit]
  fronts.drop(1).each do |front|
    name = "住宅链路｜#{front["name"]}"
    raise "住宅链路名称冲突" if proxy_map.key?(name) || group_map.key?(name)
    proxies << residential_base.merge("name" => name, "dialer-proxy" => front["name"])
    chain_names << name
  end
  # Include-all airport groups must not collect the generated residential exits.
  groups.each do |g|
    if g["include-all"] || g["include-all-proxies"]
      exclusion = "^(住宅IP-链式$|住宅链路｜)"
      existing = g["exclude-filter"].to_s
      g["exclude-filter"] = existing.empty? ? exclusion : "(?:#{existing})|#{exclusion}" unless existing.include?(exclusion)
    end
  end
  groups.unshift({"name" => "住宅链路自动", "type" => "url-test", "proxies" => chain_names,
    "url" => "https://www.gstatic.com/generate_204", "expected-status" => "204",
    "interval" => 300, "timeout" => 8000, "tolerance" => 100, "lazy" => false,
    "max-failed-times" => 2, "empty-fallback" => "REJECT"})

  proxies.unshift(residential_base)
  data["proxies"] = proxies

  # 保留交易所原定地区限制，不把主代理或住宅组加入交易所测速候选。
  regional = /(?:台湾|台灣|韩国|韓國|日本|澳大利亚|澳大利亞|澳洲|英国|英國|英伦|英倫|澳门|澳門|🇹🇼|🇰🇷|🇯🇵|🇦🇺|🇬🇧|🇲🇴|(?:^|[^A-Za-z])(?:TW|KR|JP|AU|UK|GB|MO|Taiwan|Japan|Korea|Australia|United[ -]?Kingdom|Great[ -]?Britain|Britain|England|Macau|Macao)(?:[^A-Za-z]|$))/i
  exchange = {
    "name" => exchange_group, "type" => "url-test",
    "url" => "https://www.gstatic.com/generate_204", "interval" => 600,
    "tolerance" => 50, "empty-fallback" => "REJECT"
  }
  candidates = proxy_map.keys.select { |n| n.match?(regional) && !n.match?(notice) }
  exchange["exclude-filter"] = "(?i)#{notice.source}"
  exchange["proxies"] = candidates unless candidates.empty?
  unless providers.empty?
    exchange["use"] = providers.key?("airport") ? ["airport"] : providers.keys
    exchange["filter"] = "(?i)(台湾|台灣|韩国|韓國|日本|澳大利亚|澳大利亞|澳洲|英国|英國|英伦|英倫|澳门|澳門|🇹🇼|🇰🇷|🇯🇵|🇦🇺|🇬🇧|🇲🇴|(?:^|[^A-Za-z])(?:TW|KR|JP|AU|UK|GB|MO|Taiwan|Japan|Korea|Australia|United[ -]?Kingdom|Great[ -]?Britain|Britain|England|Macau|Macao)(?:[^A-Za-z]|$))"
  end
  exchange["proxies"] = ["REJECT"] if candidates.empty? && providers.empty?
  groups.each do |g|
    has_dynamic = g["include-all"] || g["include-all-proxies"] || g["include-all-providers"] || !Array(g["use"]).empty?
    g["proxies"] = ["REJECT"] if Array(g["proxies"]).empty? && !has_dynamic
  end
  groups.unshift(exchange)
  groups.unshift({"name" => residential_group, "type" => "select", "proxies" => ["住宅链路自动"]})
  data["proxy-groups"] = groups
  data["mode"] = "rule"

  domestic = [
    "DOMAIN,localhost,DIRECT", "DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-SUFFIX,lan,DIRECT",
    "IP-CIDR,0.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve", "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve", "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
    "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
    "IP-CIDR6,::1/128,DIRECT,no-resolve", "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
    "IP-CIDR6,fe80::/10,DIRECT,no-resolve", "IP-CIDR6,ff00::/8,DIRECT,no-resolve",
    "DOMAIN-SUFFIX,cn,DIRECT"
  ]
  %w[jianying.com capcut.cn byteimg.com zijieapi.com ulikecam.com douyin.com douyincdn.com snssdk.com toutiao.com toutiaoimg.com pstatp.com].each do |domain|
    domestic << "DOMAIN-SUFFIX,#{domain},DIRECT"
  end
  domestic += ["GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT"]
  exchange_rules = %w[bybit.com bybitglobal.com bytick.com binance.com binance.info binance.me bnbstatic.com okx.com okx-dns.com saasexch.com].map do |domain|
    "DOMAIN-SUFFIX,#{domain},#{exchange_group}"
  end
  exchange_rules += %w[bybit binance okx].map { |keyword| "DOMAIN-KEYWORD,#{keyword},#{exchange_group}" }
  # 原有广告/恶意地址拒绝规则保留，其余旧站点分流由新的统一兜底取代。
  rejects = Array(data["rules"]).select do |r|
    r.is_a?(String) && r.match?(/,(?:REJECT|REJECT-DROP)(?:,no-resolve)?\z/i) && !r.match?(/\A(?:MATCH|FINAL),/i)
  end
  # Google Play API、应用包和更新 CDN 必须先于国内 GEOSITE/GEOIP 命中。
  play_rules = %w[play.google.com android.com googleusercontent.com gstatic.com
    gvt1.com ggpht.com dl.google.com dl-ssl.google.com android.apis.google.com
    gvt2.com gvt3.com googleapis.com android.clients.google.com].map do |domain|
    "DOMAIN-SUFFIX,#{domain},#{auto_name}"
  end
  data["rules"] = (exchange_rules + %w[openai.com chatgpt.com oaistatic.com oaiusercontent.com chat.com sora.com openaiapi-site.azureedge.net production-openaicom-storage.azureedge.net x.com twitter.com twimg.com t.co twitterinc.com twtrdns.net twttr.com tweetdeck.com periscope.tv pscp.tv ads-twitter.com twitteroauth.com twitterstat.us x.ai grok.com claude.ai anthropic.com anthropic.ai claudeusercontent.com].map { |d| "DOMAIN-SUFFIX,#{d},#{residential_group}" } + play_rules + domestic + rejects + ["MATCH,#{residential_group}"]).uniq

  dns = data["dns"]
  if dns.is_a?(Hash)
    stable = %w[chatgpt.com openai.com oaistatic.com oaiusercontent.com claude.ai anthropic.com anthropic.ai claudeusercontent.com].map { |d| "+.#{d}" }
    dns["fake-ip-filter"] = (Array(dns["fake-ip-filter"]) + stable).uniq
  end

  # 校验全部成功后原子替换；失败时保留原配置，不打印配置内容或凭据。
  # OpenWrt 的 ruby-yaml 不依赖 ruby-tempfile；只使用核心 File API。
  real_path = File.realpath(path)
  tmp_path = "#{real_path}.chain-#{Process.pid}.tmp"
  created = false
  begin
    File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
      created = true
      file.write(YAML.dump(data))
      file.flush
      file.fsync
    end
    File.chmod(File.stat(real_path).mode & 0777, tmp_path)
    File.rename(tmp_path, real_path)
  ensure
    File.unlink(tmp_path) if created && File.exist?(tmp_path)
  end
  warn "[住宅链式覆写] 完成：国内直连 / 交易所台韩日澳英澳门 / Google Play机场自动 / 其余住宅IP"
rescue StandardError => e
  # YAML 解析错误可能含原文，只对我们自己生成的 RuntimeError 输出说明。
  reason = e.class == RuntimeError ? e.message : e.class.to_s
  warn "[住宅链式覆写] 未写入配置：#{reason}"
  File.open(ENV.fetch("OVERWRITE_LOG"), "a") { |f| f.puts "[住宅链式覆写] 未写入配置：#{reason}" } rescue nil
  exit 1
end
' "$CONFIG_FILE"
RESULT=$?
if [ "$RESULT" -eq 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [住宅链式覆写] 成功 v2026-11-16：住宅链式、交易所、Google Play、国内直连" >> "$OVERWRITE_LOG"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') [住宅链式覆写] 失败：保留输入配置，请检查自动选择组与脚本错误" >> "$OVERWRITE_LOG"
fi
exit "$RESULT"
