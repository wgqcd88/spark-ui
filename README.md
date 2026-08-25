# Spark UI

`spark-ui` 是一个部署在 Kubernetes 中的 Helm Chart。它使用 OpenResty 反向代理 Spark
Driver UI，并在根路径提供一个可搜索的 Spark Service 索引页。索引页会在指定的命名空间中
发现 Service，将符合条件的服务链接到对应的 Spark UI。

## 前置条件

- Kubernetes 集群和 Helm 3。
- Spark Driver UI 以 Kubernetes Service 暴露，默认监听端口为 `4040`。
- `proxy.baseDomain` 对应的域名应解析到该 Chart 创建的 Service 的外部地址。
- 集群 DNS 可以解析 `<service>.<namespace>.svc.<cluster-domain>`。默认
  `clusterDomain` 为 `cluster.local`，DNS resolver 为
  `kube-dns.kube-system.svc.cluster.local`。

Chart 会为 `index.namespaces` 中的每个命名空间创建一个仅允许读取 Service 的 Role 和
RoleBinding。因此，发布者需要有在这些命名空间创建 RBAC 资源的权限。

## 安装

下面的命令从 OCI Registry 安装 Chart，并创建一个公开的 LoadBalancer：

```bash
helm upgrade --install spark-ui \
  oci://ghcr.io/wgqcd88/charts/spark-ui \
  --version 0.3.0 \
  --set proxy.baseDomain=spark.example.com \
  --set index.namespaces='{spark,flink}' \
  --set index.linkFormat=path \
  --set nodeSelector.spark-ui=support \
  --namespace default \
  --create-namespace
```

也可以使用仓库中的示例 values 文件安装：

```bash
helm upgrade --install spark-ui \
  oci://ghcr.io/wgqcd88/charts/spark-ui \
  --version 0.3.0 \
  --values spark-ui-values.yaml \
  --namespace default \
  --create-namespace
```

安装完成后，访问 `http://<base-domain>/` 可打开 Spark Service 索引。页面展示应用名称、
Spark App ID 和 Service 创建至今的运行时间，并可按应用名称、Service 名称或 App ID
实时过滤。

## Spark UI 访问方式

默认使用路径模式（`index.linkFormat=path`）。对于命名空间为 `spark`、Service 为
`example-driver` 的 Spark 应用，作业页地址为：

```text
http://<base-domain>/example-driver/spark/jobs
```

除 `/jobs` 外，代理会转发该 Spark UI 下的其他路径、查询参数和 API 请求。路径模式还会
重写 Spark UI 返回的绝对链接，使页面内的导航、静态资源和 API 请求继续经过代理。

### 子域名兼容模式

将 `index.linkFormat` 设为 `subdomain` 时，索引会生成以下旧格式链接：

```text
http://spark--example-driver.<base-domain>/
```

无论索引链接模式为何，Chart 都会保留对上述子域名请求的代理支持。要使用该方式，DNS 或
Ingress 必须将 `*.<base-domain>` 路由到 `spark-ui` Service。

## 服务发现规则

索引会轮询 `index.namespaces` 中每个命名空间的 Kubernetes Service API，并缓存未搜索
的索引页面 `index.cacheSeconds` 秒。以下 Service 会被识别为 Spark UI：

- Service 未定义任何端口；或
- Service 至少有一个端口等于 `proxy.upstream.port`（默认 `4040`）。

页面优先使用 `metadata.labels.spark-app-name` 作为应用名称，其次使用
`spec.selector.spark-app-name`，最后回退为 Service 名称。Spark App ID 同样从标签或
selector 中的 `spark-app-selector` 获取。

单个命名空间读取失败时，索引页仍会展示其他可访问命名空间中的 Spark Service，并在页面
中列出失败的命名空间和排查提示。权限错误（HTTP 403）通常表示对应命名空间中的 Role 或
RoleBinding 缺失。包含读取失败提示的页面不会被缓存，修复权限或配置后刷新即可恢复；如果
所有命名空间均读取失败，页面会显示友好错误说明并返回 HTTP 503。

## 配置

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `replicaCount` | `1` | 代理 Pod 副本数。 |
| `image.repository` | `openresty/openresty` | OpenResty 镜像仓库。 |
| `image.tag` | `1.31.1.1-2-alpine-fat` | OpenResty 镜像标签。 |
| `image.pullPolicy` | `IfNotPresent` | 镜像拉取策略。 |
| `service.type` | `LoadBalancer` | 对外暴露代理的 Service 类型。 |
| `service.port` | `80` | Service 对外 HTTP 端口。 |
| `service.annotations` | `{}` | 追加到 Service 的注解，例如云负载均衡器注解。 |
| `proxy.baseDomain` | `<base_domain>` | 访问索引和生成链接使用的基础域名。安装时必须替换。 |
| `proxy.resolver` | `kube-dns.kube-system.svc.cluster.local` | 用于解析 Spark Service 的集群 DNS resolver。 |
| `proxy.clusterDomain` | `cluster.local` | Kubernetes Service DNS 后缀。 |
| `proxy.upstream.port` | `4040` | Spark UI Service 端口，也是服务发现使用的端口。 |
| `index.scheme` | `http` | 索引生成链接使用的协议；HTTPS 终止在外部 Ingress/LB 时设为 `https`。 |
| `index.linkFormat` | `path` | 索引链接格式，可选 `path` 或 `subdomain`。 |
| `index.cacheSeconds` | `30` | 未带搜索参数的索引页缓存秒数；设为 `0` 表示不设置过期时间。 |
| `index.namespaces` | `["<namespace>"]` | 要发现 Spark Service 的命名空间列表，同时决定创建 RBAC 的范围。 |
| `resources` | CPU `1`、内存 `4Gi` | OpenResty 容器的 requests 和 limits。 |
| `nodeSelector` | `{}` | Pod 节点选择器。 |
| `tolerations` | `[]` | Pod tolerations。 |
| `affinity` | `{}` | Pod affinity/anti-affinity 配置。 |

`index.linkFormat` 只能取 `path` 或 `subdomain`；其他值会使 Helm 渲染失败，避免生成不可用的
链接。

## 配置示例

以下示例将代理部署在内部 Azure LoadBalancer 后面，通过 HTTPS 域名访问，并同时发现
`data-platform` 和 `spark` 命名空间中的应用：

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"

proxy:
  baseDomain: spark-ui.example.com
  resolver: kube-dns.kube-system.svc.cluster.local
  clusterDomain: cluster.local
  upstream:
    port: 4040

index:
  scheme: https
  linkFormat: path
  cacheSeconds: 30
  namespaces:
    - data-platform
    - spark

nodeSelector:
  spark-ui: support
```

将配置保存为 `values.yaml` 后执行：

```bash
helm upgrade --install spark-ui \
  oci://ghcr.io/wgqcd88/charts/spark-ui \
  --version 0.3.0 \
  --values values.yaml \
  --namespace default \
  --create-namespace
```

## 升级与卸载

使用相同的 release 名称和 values 文件即可升级：

```bash
helm upgrade spark-ui \
  oci://ghcr.io/wgqcd88/charts/spark-ui \
  --version 0.3.0 \
  --values values.yaml \
  --namespace default
```

卸载会删除代理工作负载、ServiceAccount 以及在已配置命名空间中创建的 Service 读取权限：

```bash
helm uninstall spark-ui --namespace default
```
