local cjson = require "cjson.safe"
local cache = ngx.shared.spark_service_index
local cache_key = "services:v1"

local namespaces = {
{{- range .Values.index.namespaces }}
  {{ . | quote }},
{{- end }}
}

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

local function get_namespace_services(namespace)
  local response = ngx.location.capture("/_kubernetes_services", {
    args = { namespace = namespace }
  })

  if not response or response.status ~= ngx.HTTP_OK then
    local status = response and response.status or 502
    ngx.log(
      ngx.ERR,
      "Kubernetes Service API returned ",
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
      "Kubernetes Service API returned invalid JSON for namespace ",
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

local discovered_services = {}
local namespace_errors = {}
local successful_namespaces = 0

for _, namespace in ipairs(namespaces) do
  local services, request_error = get_namespace_services(namespace)
  if request_error then
    request_error.namespace = namespace
    namespace_errors[#namespace_errors + 1] = request_error
  else
    successful_namespaces = successful_namespaces + 1

    for _, service in ipairs(services) do
      local metadata = service.metadata or {}
      local name = metadata.name
      local service_type
      if is_flink_service(service) then
        service_type = "flink"
      elseif is_spark_service(service) then
        service_type = "spark"
      end

      if name and service_type then
        local labels = metadata.labels or {}
        local selector = service.spec and service.spec.selector or {}
        local display_name = labels["spark-app-name"] or selector["spark-app-name"]
          or labels["app"] or labels["cluster-id"] or name
        local app_id = labels["spark-app-selector"] or selector["spark-app-selector"]
          or labels["cluster-id"] or labels["app"]

        discovered_services[#discovered_services + 1] = {
          namespace = namespace,
          name = name,
          displayName = display_name,
          appId = app_id or cjson.null,
          createdAt = metadata.creationTimestamp or cjson.null,
          type = service_type,
          url = service_url(namespace, name, service_type)
        }
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
    totalNamespaces = #namespaces,
    successfulNamespaces = successful_namespaces,
    failedNamespaces = #namespace_errors
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
