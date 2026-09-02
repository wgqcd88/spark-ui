local cjson = require "cjson.safe"
local cache = ngx.shared.spark_service_index
local discovery_mode = "{{ .Values.index.discoveryMode }}"

local function query_arg(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local query = query_arg(ngx.var.arg_q)
if query then
  query = string.lower(query)
end

local filter_type = query_arg(ngx.var.arg_type)
if filter_type ~= "spark" and filter_type ~= "flink" then
  filter_type = nil
end

local filter_namespace = query_arg(ngx.var.arg_namespace)
local cache_key = table.concat({
  "services",
  discovery_mode,
  filter_type or "all",
  filter_namespace or "all",
  query or "all",
  "v2"
}, ":")

local namespaces = {
{{- range .Values.index.namespaces }}
  {{ . | quote }},
{{- end }}
}

local selected_namespaces = {}
for _, namespace in ipairs(namespaces) do
  if not filter_namespace or namespace == filter_namespace then
    selected_namespaces[#selected_namespaces + 1] = namespace
  end
end

local function as_json_array(items)
  if #items == 0 and cjson.empty_array ~= nil then
    return cjson.empty_array
  end
  return items
end

local function set_response_headers()
  ngx.header.content_type = "application/json; charset=utf-8"
  ngx.header["Cache-Control"] = "no-store, max-age=0"
  ngx.header["Pragma"] = "no-cache"
end

local cached_response = cache:get(cache_key)
if cached_response then
  set_response_headers()
  ngx.status = ngx.HTTP_OK
  ngx.print(cached_response)
  return
end

local function namespace_error(status)
  if status == 401 then
    return { status = status, code = "unauthorized" }
  end
  if status == 403 then
    return { status = status, code = "forbidden" }
  end
  if status == 404 then
    return { status = status, code = "namespace_not_found" }
  end
  return { status = status, code = "upstream_error" }
end

local function get_namespace_resources(namespace)
  local location = discovery_mode == "pod" and "/_kubernetes_pods" or "/_kubernetes_services"
  local response = ngx.location.capture(location, {
    args = { namespace = namespace }
  })

  if not response or response.status ~= ngx.HTTP_OK then
    local status = response and response.status or 502
    ngx.log(
      ngx.ERR,
      "Kubernetes API returned ",
      status,
      " for namespace ",
      namespace
    )
    return nil, namespace_error(status)
  end

  local services, decode_error = cjson.decode(response.body)
  if type(services) ~= "table" or type(services.items) ~= "table" then
    ngx.log(
      ngx.ERR,
      "Kubernetes API returned invalid JSON for namespace ",
      namespace,
      ": ",
      decode_error or "missing items"
    )
    return nil, { status = 502, code = "invalid_response" }
  end

  return services.items
end

local function is_spark_service(service)
  local labels = service.metadata and service.metadata.labels or {}
  if labels.type == "flink-native-kubernetes" then
    return false
  end

  local ports = service.spec and service.spec.ports or {}
  if #ports == 0 then
    return true
  end

  for _, port in ipairs(ports) do
    if port.port == {{ .Values.proxy.upstream.port }} then
      return true
    end
  end

  return false
end

local function is_flink_service(service)
  local labels = service.metadata and service.metadata.labels or {}
  if labels.type ~= "flink-native-kubernetes" then
    return false
  end

  local ports = service.spec and service.spec.ports or {}
  for _, port in ipairs(ports) do
    if port.port == {{ .Values.proxy.flinkUpstream.port }} then
      return true
    end
  end

  return false
end

local function has_port(resource, expected_port)
  for _, container in ipairs(resource.spec and resource.spec.containers or {}) do
    for _, port in ipairs(container.ports or {}) do
      if port.containerPort == expected_port then
        return true
      end
    end
  end
  return false
end

local function is_spark_pod(pod)
  local labels = pod.metadata and pod.metadata.labels or {}
  return pod.status and pod.status.phase == "Running"
    and pod.status.podIP
    and labels["spark-role"] == "driver"
    and has_port(pod, {{ .Values.proxy.upstream.port }})
end

local function is_flink_pod(pod)
  local labels = pod.metadata and pod.metadata.labels or {}
  return pod.status and pod.status.phase == "Running"
    and pod.status.podIP
    and labels.type == "flink-native-kubernetes"
    and labels.component == "jobmanager"
    and has_port(pod, {{ .Values.proxy.flinkUpstream.port }})
end

local function service_url(namespace, name, service_type)
{{- if eq .Values.index.linkFormat "path" }}
  if service_type == "flink" then
    return string.format(
      "/flink/%s/%s/",
      name,
      namespace
    )
  end

  return string.format(
    "/%s/%s/jobs",
    name,
    namespace
  )
{{- else }}
  if service_type == "flink" then
    return string.format(
      "{{ .Values.index.scheme }}://flink--%s--%s.{{ .Values.proxy.baseDomain }}",
      namespace,
      name
    )
  end

  return string.format(
    "{{ .Values.index.scheme }}://%s--%s.{{ .Values.proxy.baseDomain }}",
    namespace,
    name
  )
{{- end }}
end

local function pod_url(pod_ip, service_type)
  if service_type == "flink" then
    return string.format("/pod/flink/%s/", pod_ip)
  end
  return string.format("/pod/spark/%s/jobs", pod_ip)
end

local function text_value(value)
  return type(value) == "string" and value or ""
end

local function matches_query(service)
  if not query then
    return true
  end

  local search_text = table.concat({
    text_value(service.namespace),
    text_value(service.name),
    text_value(service.displayName),
    text_value(service.appId),
    text_value(service.type)
  }, " ")
  return string.lower(search_text):find(query, 1, true) ~= nil
end

local discovered_services = {}
local namespace_errors = {}
local successful_namespaces = 0

for _, namespace in ipairs(selected_namespaces) do
  local resources, request_error = get_namespace_resources(namespace)
  if request_error then
    request_error.namespace = namespace
    namespace_errors[#namespace_errors + 1] = request_error
  else
    successful_namespaces = successful_namespaces + 1

    for _, resource in ipairs(resources) do
      local metadata = resource.metadata or {}
      local name = metadata.name
      local service_type
      if discovery_mode == "pod" then
        if is_flink_pod(resource) then
          service_type = "flink"
        elseif is_spark_pod(resource) then
          service_type = "spark"
        end
      else
        if is_flink_service(resource) then
          service_type = "flink"
        elseif is_spark_service(resource) then
          service_type = "spark"
        end
      end

      if name and service_type and (not filter_type or service_type == filter_type) then
        local labels = metadata.labels or {}
        local selector = resource.spec and resource.spec.selector or {}
        local display_name = labels["spark-app-name"] or selector["spark-app-name"]
          or labels["app"] or labels["cluster-id"] or name
        local app_id = labels["spark-app-selector"] or selector["spark-app-selector"]
          or labels["cluster-id"] or labels["app"]

        local discovered_service = {
          namespace = namespace,
          name = name,
          displayName = display_name,
          appId = app_id or cjson.null,
          createdAt = metadata.creationTimestamp or cjson.null,
          type = service_type,
          url = discovery_mode == "pod"
            and pod_url(resource.status.podIP, service_type)
            or service_url(namespace, name, service_type)
        }

        if matches_query(discovered_service) then
          discovered_services[#discovered_services + 1] = discovered_service
        end
      end
    end
  end
end

table.sort(discovered_services, function(left, right)
  local left_key = string.lower(left.namespace .. "\0" .. left.displayName .. "\0" .. left.name)
  local right_key = string.lower(right.namespace .. "\0" .. right.displayName .. "\0" .. right.name)
  return left_key < right_key
end)

local response_payload = {
  services = as_json_array(discovered_services),
  errors = as_json_array(namespace_errors),
  summary = {
    totalNamespaces = #selected_namespaces,
    successfulNamespaces = successful_namespaces,
    failedNamespaces = #namespace_errors,
    namespaces = as_json_array(namespaces),
    filters = {
      q = query or cjson.null,
      type = filter_type or cjson.null,
      namespace = filter_namespace or cjson.null
    }
  }
}

local response_body, encode_error = cjson.encode(response_payload)
local response_status = ngx.HTTP_OK

if not response_body then
  ngx.log(ngx.ERR, "Failed to encode Spark service API response: ", encode_error or "unknown error")
  response_body = '{"services":[],"errors":[{"namespace":"index","status":500,"code":"encode_error"}],"summary":{"totalNamespaces":0,"successfulNamespaces":0,"failedNamespaces":1}}'
  response_status = ngx.HTTP_INTERNAL_SERVER_ERROR
elseif #namespace_errors == 0 then
  cache:set(cache_key, response_body, {{ .Values.index.cacheSeconds }})
else
  cache:delete(cache_key)
  if #namespaces > 0 and successful_namespaces == 0 then
    response_status = ngx.HTTP_SERVICE_UNAVAILABLE
  end
end

set_response_headers()
ngx.status = response_status
ngx.print(response_body)
