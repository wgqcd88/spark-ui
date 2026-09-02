const state = {
  services: [],
  successfulNamespaces: 0,
  loading: false
};

const searchForm = document.getElementById("service-search-form");
const searchInput = document.getElementById("service-search");
const typeFilter = document.getElementById("service-type-filter");
const namespaceFilter = document.getElementById("service-namespace-filter");
const refreshButton = document.getElementById("refresh-services");
const serviceList = document.getElementById("service-list");
const loadStatus = document.getElementById("load-status");
const warning = document.getElementById("namespace-warning");
const warningTitle = document.getElementById("warning-title");
const warningSummary = document.getElementById("warning-summary");
const warningList = document.getElementById("warning-list");
let pendingNamespaceFilter = "";
let searchTimer = 0;

function arrayValue(value) {
  return Array.isArray(value) ? value : [];
}

function stringValue(value) {
  return typeof value === "string" ? value : "";
}

function errorMessage(error) {
  switch (error.code) {
    case "unauthorized":
      return "身份认证失败（HTTP 401），请检查 ServiceAccount 配置。";
    case "forbidden":
      return "无权读取 Service（HTTP 403），请检查该命名空间中的 Role 和 RoleBinding 是否存在。";
    case "namespace_not_found":
      return "命名空间不存在（HTTP 404），请检查 index.namespaces 配置。";
    case "invalid_response":
      return "Kubernetes API 返回了异常数据，请稍后重试。";
    case "encode_error":
      return "服务发现结果处理失败，请查看服务端日志。";
    case "request_failed":
      return "无法连接服务发现接口，请检查网络后重试。";
    default: {
      const status = Number(error.status);
      return status > 0
        ? `Kubernetes API 请求失败（HTTP ${status}），请稍后重试。`
        : "Kubernetes API 请求失败，请稍后重试。";
    }
  }
}

function renderWarnings(errors, successfulNamespaces) {
  warningList.replaceChildren();

  if (errors.length === 0) {
    warning.hidden = true;
    return;
  }

  const partiallyAvailable = successfulNamespaces > 0;
  warningTitle.textContent = partiallyAvailable
    ? "部分命名空间加载失败"
    : "Spark 和 Flink 服务暂时无法加载";
  warningSummary.textContent = partiallyAvailable
    ? "已展示其他可正常访问命名空间中的结果；失败命名空间的数据暂未显示。"
    : "所有命名空间均读取失败，请根据以下提示检查权限或配置后刷新页面。";

  for (const error of errors) {
    const item = document.createElement("li");
    const namespace = document.createElement("strong");
    namespace.textContent = stringValue(error.namespace) || "未知命名空间";
    item.append(namespace, `：${errorMessage(error)}`);
    warningList.append(item);
  }

  warning.hidden = false;
}

function formatDuration(timestamp) {
  const startedAt = Date.parse(stringValue(timestamp));
  if (!Number.isFinite(startedAt)) {
    return "-";
  }

  let seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  const days = Math.floor(seconds / 86400);
  seconds %= 86400;
  const hours = Math.floor(seconds / 3600);
  seconds %= 3600;
  const minutes = Math.floor(seconds / 60);
  seconds %= 60;

  if (days > 0) {
    return `${days}d ${String(hours).padStart(2, "0")}h ${String(minutes).padStart(2, "0")}m ${String(seconds).padStart(2, "0")}s`;
  }
  if (hours > 0) {
    return `${hours}h ${String(minutes).padStart(2, "0")}m ${String(seconds).padStart(2, "0")}s`;
  }
  if (minutes > 0) {
    return `${minutes}m ${String(seconds).padStart(2, "0")}s`;
  }
  return `${seconds}s`;
}

function searchableText(service) {
  return [service.namespace, service.name, service.displayName, service.appId, service.type]
    .map(stringValue)
    .join(" ")
    .toLocaleLowerCase();
}

function serviceCategory(service) {
  return stringValue(service.type) === "flink"
    ? {
      name: "Flink",
      icon: "/assets/flink-logo.svg",
      className: "flink"
    }
    : {
      name: "Spark",
      icon: "/assets/spark-logo.svg",
      className: "spark"
    };
}

function emptyMessage(query) {
  if (query || typeFilter.value || namespaceFilter.value) {
    return "没有匹配的 Spark 或 Flink 服务。";
  }
  if (state.successfulNamespaces > 0) {
    return "未在可访问的命名空间中发现 Spark 或 Flink 服务。";
  }
  return "暂时无法加载 Spark 或 Flink 服务。";
}

function updateNamespaceFilter(namespaces) {
  const selectedNamespace = pendingNamespaceFilter || namespaceFilter.value;
  const visibleNamespaces = [...new Set(namespaces.map(stringValue).filter(Boolean))]
    .sort((left, right) => left.localeCompare(right));

  namespaceFilter.replaceChildren();
  namespaceFilter.append(new Option("全部命名空间", ""));
  for (const namespace of visibleNamespaces) {
    namespaceFilter.append(new Option(namespace, namespace));
  }

  namespaceFilter.value = visibleNamespaces.includes(selectedNamespace) ? selectedNamespace : "";
  pendingNamespaceFilter = "";
}

function renderServices() {
  serviceList.replaceChildren();

  if (state.loading) {
    const item = document.createElement("li");
    item.className = "state-message";
    item.textContent = "正在加载 Spark 和 Flink 服务…";
    serviceList.append(item);
    return;
  }

  const query = searchInput.value.trim().toLocaleLowerCase();
  const visibleServices = state.services;

  if (visibleServices.length === 0) {
    const item = document.createElement("li");
    item.className = "state-message";
    item.textContent = emptyMessage(query);
    serviceList.append(item);
    return;
  }

  for (const service of visibleServices) {
    const item = document.createElement("li");
    item.className = "service-row";

    const link = document.createElement("a");
    link.className = "service-link";
    link.href = stringValue(service.url);
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = `${stringValue(service.namespace)}/${stringValue(service.displayName) || stringValue(service.name)}`;

    const category = serviceCategory(service);
    const categoryBadge = document.createElement("span");
    categoryBadge.className = `service-category ${category.className}`;
    categoryBadge.title = category.name;

    const categoryIcon = document.createElement("img");
    categoryIcon.className = "service-category-icon";
    categoryIcon.src = category.icon;
    categoryIcon.alt = "";
    categoryIcon.width = category.className === "spark" ? 68 : 26;
    categoryIcon.height = 26;
    categoryBadge.setAttribute("aria-label", category.name);
    categoryBadge.append(categoryIcon);
    if (category.className === "flink") {
      const categoryName = document.createElement("span");
      categoryName.textContent = category.name;
      categoryBadge.append(categoryName);
    }

    const appId = document.createElement("span");
    appId.className = "app-id";
    appId.textContent = stringValue(service.appId) || "-";

    const runtime = document.createElement("span");
    runtime.className = "runtime";
    runtime.dataset.createdAt = stringValue(service.createdAt);
    runtime.textContent = formatDuration(service.createdAt);

    item.append(link, categoryBadge, appId, runtime);
    serviceList.append(item);
  }
}

function updateRuntimes() {
  for (const runtime of document.querySelectorAll(".runtime[data-created-at]")) {
    runtime.textContent = formatDuration(runtime.dataset.createdAt);
  }
}

function updateQueryUrl() {
  const url = new URL(window.location.href);
  const query = searchInput.value.trim();
  const selectedType = typeFilter.value;
  const selectedNamespace = namespaceFilter.value;
  if (query) {
    url.searchParams.set("q", query);
  } else {
    url.searchParams.delete("q");
  }
  if (selectedType) {
    url.searchParams.set("type", selectedType);
  } else {
    url.searchParams.delete("type");
  }
  if (selectedNamespace) {
    url.searchParams.set("namespace", selectedNamespace);
  } else {
    url.searchParams.delete("namespace");
  }
  window.history.replaceState(null, "", url);
}

function serviceApiUrl() {
  const url = new URL("/api/services", window.location.origin);
  const query = searchInput.value.trim();
  const selectedType = typeFilter.value;
  const selectedNamespace = namespaceFilter.value;

  if (query) {
    url.searchParams.set("q", query);
  }
  if (selectedType) {
    url.searchParams.set("type", selectedType);
  }
  if (selectedNamespace) {
    url.searchParams.set("namespace", selectedNamespace);
  }

  return `${url.pathname}${url.search}`;
}

function scheduleLoadServices() {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(loadServices, 250);
}

function updateLoadStatus(serviceCount, errors) {
  if (errors.length > 0 && state.successfulNamespaces === 0) {
    loadStatus.textContent = "服务列表加载失败。";
  } else if (errors.length > 0) {
    loadStatus.textContent = `已加载 ${serviceCount} 个应用，${errors.length} 个命名空间加载失败。`;
  } else {
    loadStatus.textContent = `已加载 ${serviceCount} 个应用。`;
  }
}

async function loadServices() {
  state.loading = true;
  refreshButton.disabled = true;
  loadStatus.textContent = "正在从 Kubernetes 加载服务…";
  renderServices();

  try {
    const response = await fetch(serviceApiUrl(), {
      headers: { Accept: "application/json" },
      cache: "no-store"
    });

    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new Error("invalid API response");
    }

    const services = arrayValue(payload && payload.services);
    const errors = arrayValue(payload && payload.errors);
    if (!response.ok && errors.length === 0) {
      throw new Error(`service API returned ${response.status}`);
    }

    const summary = payload && typeof payload.summary === "object" ? payload.summary : {};
    const successfulNamespaces = Number(summary.successfulNamespaces);
    const namespaces = arrayValue(summary.namespaces);

    state.services = services;
    state.successfulNamespaces = Number.isFinite(successfulNamespaces) ? successfulNamespaces : 0;
    updateNamespaceFilter(namespaces.length > 0 ? namespaces : services.map((service) => service.namespace));
    renderWarnings(errors, state.successfulNamespaces);
    updateLoadStatus(services.length, errors);
  } catch (error) {
    console.error("Failed to load Spark and Flink services", error);
    state.services = [];
    state.successfulNamespaces = 0;
    const errors = [{ namespace: "服务发现接口", status: 0, code: "request_failed" }];
    renderWarnings(errors, 0);
    updateLoadStatus(0, errors);
  } finally {
    state.loading = false;
    refreshButton.disabled = false;
    renderServices();
  }
}

const initialQuery = new URLSearchParams(window.location.search).get("q");
const initialType = new URLSearchParams(window.location.search).get("type");
const initialNamespace = new URLSearchParams(window.location.search).get("namespace");
searchInput.value = initialQuery || "";
typeFilter.value = initialType === "spark" || initialType === "flink" ? initialType : "";
pendingNamespaceFilter = initialNamespace || "";

searchForm.addEventListener("submit", (event) => {
  event.preventDefault();
  updateQueryUrl();
  loadServices();
});

searchInput.addEventListener("input", () => {
  updateQueryUrl();
  scheduleLoadServices();
});

typeFilter.addEventListener("change", () => {
  updateQueryUrl();
  loadServices();
});

namespaceFilter.addEventListener("change", () => {
  updateQueryUrl();
  loadServices();
});

refreshButton.addEventListener("click", loadServices);

window.addEventListener("popstate", () => {
  const searchParams = new URLSearchParams(window.location.search);
  const type = searchParams.get("type");
  searchInput.value = searchParams.get("q") || "";
  typeFilter.value = type === "spark" || type === "flink" ? type : "";
  pendingNamespaceFilter = searchParams.get("namespace") || "";
  updateNamespaceFilter(arrayValue(state.services.map((service) => service.namespace)));
  loadServices();
});

window.setInterval(updateRuntimes, 1000);
loadServices();
