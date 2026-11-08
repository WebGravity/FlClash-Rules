const main = (config) => {

  // ================================
  // 1. 基础设置
  // ================================

  const MAIN = "OpenAI";
  const TEST_URL = "https://www.gstatic.com/generate_204";

  const INTERVAL = 300;
  const TOLERANCE = 100;

  // ================================
  // 2. 国家及地区识别
  // ================================

  const regions = [
    {
      name: "美国自动",
      regex: /美国|美國|🇺🇸|\bUS\b|\bUSA\b|United States|LAX|SFO|JFK|SJC|Los Angeles|New York/i
    },
    {
      name: "日本自动",
      regex: /日本|🇯🇵|\bJP\b|Japan|Tokyo|Osaka|NRT|HND|KIX/i
    },
    {
      name: "韩国自动",
      regex: /韩国|韓國|南韩|南韓|🇰🇷|\bKR\b|Korea|Seoul|ICN|PUS/i
    },
    {
      name: "新加坡自动",
      regex: /新加坡|狮城|獅城|🇸🇬|\bSG\b|Singapore|SIN/i
    },
    {
      name: "台湾自动",
      regex: /台湾|台灣|🇹🇼|\bTW\b|Taiwan|Taipei|TPE|KHH/i
    },
    {
      name: "朝鲜自动",
      regex: /朝鲜|朝鮮|北韩|北韓|🇰🇵|\bKP\b|North Korea|DPRK|Pyongyang/i
    }
  ];

  // 排除流量信息、套餐信息等伪节点
  const EXCLUDE = /剩余|流量|到期|过期|官网|套餐|重置|有效期/i;

  // ================================
  // 3. 读取机场节点
  // ================================

  const nodes = Array.isArray(config.proxies)
    ? config.proxies
    : [];

  const providers = config["proxy-providers"] || {};
  const providerNames = Object.keys(providers);

  const groups = [];
  const availableGroups = [];

  // ================================
  // 4. 创建地区自动测速组
  // ================================

  regions.forEach((region) => {

    const matchedNodes = nodes
      .filter((node) =>
        node &&
        typeof node.name === "string" &&
        region.regex.test(node.name) &&
        !EXCLUDE.test(node.name)
      )
      .map((node) => node.name);

    // 没有直接节点且没有代理提供者，则跳过
    if (
      matchedNodes.length === 0 &&
      providerNames.length === 0
    ) {
      return;
    }

    const group = {
      name: region.name,
      type: "url-test",
      url: TEST_URL,
      interval: INTERVAL,
      tolerance: TOLERANCE,
      lazy: true
    };

    if (matchedNodes.length > 0) {
      group.proxies = [...new Set(matchedNodes)];
    }

    // 兼容 proxy-providers
    if (providerNames.length > 0) {
      group.use = providerNames;
      group.filter = region.regex.source;
      group["exclude-filter"] = EXCLUDE.source;
    }

    groups.push(group);
    availableGroups.push(region.name);

  });

  // ================================
  // 5. 创建 OpenAI 主策略组
  // ================================

  if (availableGroups.length === 0) {
    throw new Error(
      "未找到匹配的地区节点，请检查机场订阅"
    );
  }

  groups.unshift({
    name: MAIN,
    type: "select",
    proxies: availableGroups
  });

  // ================================
  // 6. 保留机场原有策略组
  // ================================

  const managedNames = [
    MAIN,
    ...regions.map((region) => region.name)
  ];

  const oldGroups = Array.isArray(config["proxy-groups"])
    ? config["proxy-groups"].filter((group) =>
        group &&
        !managedNames.includes(group.name)
      )
    : [];

  config["proxy-groups"] = groups.concat(oldGroups);

  // ================================
  // 7. OpenAI 官方域名
  // ================================

  // 通配符域名使用 DOMAIN-SUFFIX
  const suffixDomains = [
    "auth.openai.com",
    "chatgpt.com",
    "ct.sendgrid.net",
    "intercom.io",
    "intercomcdn.com",
    "oaistatic.com",
    "oaiusercontent.com",
    "openai.com",
    "oaistatsig.com"
  ];

  // 精确域名使用 DOMAIN
  const exactDomains = [
    "android.chat.openai.com",
    "auth0.openai.com",
    "cdn.openaimerge.com",
    "cdn.platform.openai.com",
    "cdn.workos.com",
    "challenges.cloudflare.com",
    "chat.openai.com",
    "desktop.chat.openai.com",
    "forwarder.workos.com",
    "frontend-apps-multi-region.workos.com",
    "humb.apple.com",
    "images.workoscdn.com",
    "ios.chat.openai.com",
    "js.intercomcdn.com",
    "js.stripe.com",
    "o207216.ingest.sentry.io",
    "o33249.ingest.sentry.io",
    "rum.browser-intake-datadoghq.com",
    "setup.auth.openai.com",
    "setup.workos.com",
    "tcr9i.chat.openai.com",
    "workos.imgix.net"
  ];

  // ================================
  // 8. 生成分流规则
  // ================================

  const gptRules = [
    ...suffixDomains.map(
      (domain) =>
        `DOMAIN-SUFFIX,${domain},${MAIN}`
    ),
    ...exactDomains.map(
      (domain) =>
        `DOMAIN,${domain},${MAIN}`
    )
  ];

  // ================================
  // 9. 保留机场原有规则
  // ================================

  const oldRules = Array.isArray(config.rules)
    ? config.rules.filter((rule) => {
        if (typeof rule !== "string") return true;

        const parts = rule.split(",");

        // 清除旧的 OpenAI 专用分流规则
        return !(
          parts.length >= 3 &&
          parts[2] === MAIN
        );
      })
    : [];

  // OpenAI 规则优先匹配
  config.rules = gptRules.concat(oldRules);

  // ================================
  // 10. 返回配置
  // ================================

  return config;

};
