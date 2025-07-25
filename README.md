# Collecting customer Network Interface Metrics on AKS Telegraf

This directory contains a Telegraf DaemonSet configuration that collects network interface statistics from AKS nodes and exposes them as Prometheus metrics for scraping by Azure Managed Prometheus.

## Overview

This solution uses a **cloud-native observability approach** with:
- **Telegraf DaemonSet**: Collects network interface metrics from each AKS node
- **Prometheus metrics endpoint**: Exposes metrics on `localhost:2112/metrics`
- **PodMonitor**: Configures Azure Managed Prometheus to scrape the metrics
- **Azure Managed Grafana**: Visualizes the collected metrics

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   AKS Nodes     │    │  Azure Managed   │    │  Azure Managed  │
│                 │    │   Prometheus     │    │    Grafana      │
│ ┌─────────────┐ │    │                  │    │                 │
│ │  Telegraf   │ │───>│  Scrapes via     │───>│  Dashboards &   │
│ │ DaemonSet   │ │    │  PodMonitor      │    │  Alerting       │
│ │:2112/metrics│ │    │                  │    │                 │
│ └─────────────┘ │    └──────────────────┘    └─────────────────┘
└─────────────────┘
```

## Components

This solution includes all necessary Kubernetes resources:
- **ConfigMap**: Contains Telegraf configuration and network parsing script
- **DaemonSet**: Deploys Telegraf with privileged access to host network
- **Service**: Exposes Prometheus metrics endpoint
- **PodMonitor**: Configures Azure Managed Prometheus integration
- **ServiceAccount**: Provides appropriate RBAC permissions

**Available deployment methods:**
- **File-based**: Use `telegraf-daemonset.yaml` for traditional deployment
- **Inline**: Use heredoc for copy-paste deployment without external files

## Features

- **Comprehensive network metrics**: Collects statistics from all network interfaces including:
  - Interface name, state, and MTU
  - RX/TX bytes, packets, errors, dropped packets
  - Multicast and collision statistics
- **Prometheus-native**: Exposes metrics in Prometheus format with proper labels
- **Azure integration**: Works seamlessly with Azure Managed Prometheus and Grafana
- **Scalable**: Runs as a DaemonSet to collect from all nodes in the cluster
- **Cloud-native**: Uses standard Kubernetes monitoring patterns

## Prerequisites

1. **AKS cluster** with Azure Managed Prometheus enabled
2. **Azure Managed Grafana** instance connected to the cluster
3. **PodMonitor CRD** installed (part of Azure Managed Prometheus)

### Setting up Azure Managed Prometheus and Grafana

If you don't have Azure Managed Prometheus and Grafana set up yet, follow this guide: [AKS Labs - Advanced Observability](https://azure-samples.github.io/aks-labs/docs/operations/observability-and-monitoring)

![YouTube video](https://www.youtube.com/watch?v=Dc0TqbAkQX0)

### Verifying PodMonitor CRD Installation

Before deploying, ensure the PodMonitor CRD is available in your cluster:

```bash
# Check if PodMonitor CRD exists
kubectl get crd | grep podmonitor

# Expected output (Azure Managed Prometheus):
# podmonitors.azmonitoring.coreos.com                  2025-07-23T19:12:02Z

# Alternative check
kubectl api-resources | grep podmonitor
```

If the PodMonitor CRD is not available, you need to enable Azure Managed Prometheus on your AKS cluster:

```bash
# Enable Azure Managed Prometheus (requires Azure CLI with aks-preview extension)
az aks update \
  --resource-group <your-resource-group> \
  --name <your-cluster-name> \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id <workspace-id>
```

## Quick Start

### 1. Deploy the Telegraf DaemonSet

```bash
# Deploy all components inline
cat <<EOF> telegraf-daemonset.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: telegraf-config
  namespace: default
data:
  telegraf.conf: |
    [global_tags]
      environment = "aks"
      cluster = "aks-cluster"

    [agent]
      interval = "30s"
      round_interval = true
      metric_batch_size = 1000
      metric_buffer_limit = 10000
      collection_jitter = "5s"
      flush_interval = "30s"
      flush_jitter = "5s"
      precision = ""
      hostname = "$HOSTNAME"
      omit_hostname = false

    # Custom script to parse ip -s link output
    [[inputs.exec]]
      commands = ["/usr/local/bin/parse_ip_stats.sh"]
      timeout = "10s"
      data_format = "influx"
      name_override = "network_interface_stats"

    # Prometheus metrics output
    [[outputs.prometheus_client]]
      listen = ":2112"
      metric_version = 2
      path = "/metrics"
      expiration_interval = "60s"
      collectors_exclude = ["gocollector", "process"]

  parse_ip_stats.sh: |
    #!/bin/bash
    # Script to parse ip -s link output and convert to InfluxDB line protocol
    # Uses the full iproute2 package available in Ubuntu-based Telegraf image
    
    # Get the current timestamp in nanoseconds
    timestamp=\$(date +%s%N)
    hostname=\$(hostname)
    
    # Parse ip -s link output for network statistics
    ip -s link | awk -v ts="\$timestamp" -v host="\$hostname" '
    BEGIN {
        interface = "";
        state = "";
        mtu = 0;
    }
    
    # Parse interface line (e.g., "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...")
    /^[0-9]+:/ {
        # Extract interface name (handle both regular and @ notation)
        if (match(\$0, /^[0-9]+: ([^:@]+)/)) {
            interface_match = substr(\$0, RSTART, RLENGTH);
            # Remove the number and colon prefix, then trim spaces
            gsub(/^[0-9]+: */, "", interface_match);
            interface = interface_match;
        }
        
        # Extract state from flags
        if (match(\$0, /<[^>]+>/)) {
            flags = substr(\$0, RSTART+1, RLENGTH-2);
            if (index(flags, "UP")) {
                state = "up";
            } else {
                state = "down";
            }
        }
        
        # Extract MTU
        if (match(\$0, /mtu [0-9]+/)) {
            mtu_str = substr(\$0, RSTART+4, RLENGTH-4);
            mtu = mtu_str + 0;
        }
    }
    
    # Parse RX line header (RX: bytes packets errors dropped missed mcast)
    /^[[:space:]]*RX:.*bytes.*packets.*errors.*dropped.*missed.*mcast/ {
        getline; # Get the next line with the actual numbers
        gsub(/^[[:space:]]+/, ""); # Remove leading spaces
        n = split(\$0, rx_fields);
        if (n >= 6) {
            rx_bytes = rx_fields[1];
            rx_packets = rx_fields[2];
            rx_errors = rx_fields[3];
            rx_dropped = rx_fields[4];
            rx_missed = rx_fields[5];
            rx_multicast = rx_fields[6];
        }
    }
    
    # Parse TX line header (TX: bytes packets errors dropped carrier collsns)
    /^[[:space:]]*TX:.*bytes.*packets.*errors.*dropped.*carrier.*collsns/ {
        getline; # Get the next line with the actual numbers
        gsub(/^[[:space:]]+/, ""); # Remove leading spaces
        n = split(\$0, tx_fields);
        if (n >= 6 && interface != "" && interface != "lo") {
            tx_bytes = tx_fields[1];
            tx_packets = tx_fields[2];
            tx_errors = tx_fields[3];
            tx_dropped = tx_fields[4];
            tx_carrier = tx_fields[5];
            tx_collisions = tx_fields[6];
            
            # Output metrics after processing both RX and TX (skip loopback)
            printf "network_interface_stats,interface=%s,hostname=%s,state=\"%s\" ", interface, host, state;
            printf "mtu=%si,", mtu;
            printf "rx_bytes=%si,rx_packets=%si,rx_errors=%si,rx_dropped=%si,rx_missed=%si,rx_multicast=%si,", rx_bytes, rx_packets, rx_errors, rx_dropped, rx_missed, rx_multicast;
            printf "tx_bytes=%si,tx_packets=%si,tx_errors=%si,tx_dropped=%si,tx_carrier=%si,tx_collisions=%si ", tx_bytes, tx_packets, tx_errors, tx_dropped, tx_carrier, tx_collisions;
            printf "%s\n", ts;
        }
    }
    '

---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: telegraf
  namespace: default
  labels:
    app: telegraf
spec:
  selector:
    matchLabels:
      app: telegraf
  template:
    metadata:
      labels:
        app: telegraf
    spec:
      serviceAccountName: telegraf-sa
      hostNetwork: true
      hostPID: true
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: telegraf
        image: telegraf:1.28
        env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        ports:
        - name: prometheus
          containerPort: 2112
          protocol: TCP
        securityContext:
          privileged: true
          runAsUser: 0
        volumeMounts:
        - name: telegraf-config
          mountPath: /etc/telegraf
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: var-run-docker
          mountPath: /var/run/docker.sock
          readOnly: true
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
        command:
        - /bin/bash
        - -c
        - |
          # Install iproute2 if not present
          if ! command -v ip > /dev/null 2>&1; then
            apt-get update && apt-get install -y iproute2
          fi
          
          # Copy the parsing script to the expected location
          cp /etc/telegraf/parse_ip_stats.sh /usr/local/bin/parse_ip_stats.sh
          chmod +x /usr/local/bin/parse_ip_stats.sh
          
          # Start telegraf
          exec telegraf --config /etc/telegraf/telegraf.conf
      volumes:
      - name: telegraf-config
        configMap:
          name: telegraf-config
          defaultMode: 0755
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      - name: var-run-docker
        hostPath:
          path: /var/run/docker.sock
      terminationGracePeriodSeconds: 30

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: telegraf-sa
  namespace: default

---
apiVersion: v1
kind: Service
metadata:
  name: telegraf-metrics
  namespace: default
  labels:
    app: telegraf
spec:
  selector:
    app: telegraf
  ports:
  - name: prometheus
    port: 2112
    targetPort: 2112
    protocol: TCP
  type: ClusterIP

---
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: telegraf-podmonitor
  namespace: default
  labels:
    app: telegraf
spec:
  selector:
    matchLabels:
      app: telegraf
  podMetricsEndpoints:
  - port: prometheus
    interval: 30s
    path: /metrics
EOF
```
Apply it:

```bash
kubectl apply -f telegraf-daemonset.yaml
```

Verify deployment

```bash
kubectl get daemonset telegraf
kubectl get pods -l app=telegraf
kubectl get service telegraf-metrics
kubectl get podmonitor telegraf-podmonitor
```

### 2. Verify Metrics Collection

```bash
# Port-forward to check metrics endpoint
kubectl port-forward svc/telegraf-metrics 2112:2112

# Check metrics in another terminal
curl http://localhost:2112/metrics | head -20
```

Expected output:

```
# HELP network_interface_stats_mtu Telegraf collected metric
# TYPE network_interface_stats_mtu untyped
network_interface_stats_mtu{cluster="aks-cluster",environment="aks",host="node-name",interface="eth0",state="up"} 1500
# HELP network_interface_stats_rx_bytes Telegraf collected metric
# TYPE network_interface_stats_rx_bytes untyped
network_interface_stats_rx_bytes{cluster="aks-cluster",environment="aks",host="node-name",interface="eth0",state="up"} 16876971289
```

### 3. View in Grafana

1. Navigate to your Azure Managed Grafana instance
2. Go to **Explore** → Change data source to **Managed Prometheus**
3. Query examples:
   ```promql
   # Network throughput by interface
   rate(network_interface_stats_rx_bytes[5m])
   
   # Network errors across cluster
   network_interface_stats_rx_errors > 0
   
   # Top interfaces by traffic
   topk(10, network_interface_stats_tx_bytes)
   ```

## Configuration

### Network Interface Metrics

The solution collects the following metrics for each network interface using `ip -s link`:

| Metric | Type | Description |
|--------|------|-------------|
| `network_interface_stats_mtu` | gauge | Maximum Transmission Unit |
| `network_interface_stats_rx_bytes` | counter | Received bytes |
| `network_interface_stats_rx_packets` | counter | Received packets |
| `network_interface_stats_rx_errors` | counter | Receive errors |
| `network_interface_stats_rx_dropped` | counter | Received packets dropped |
| `network_interface_stats_rx_missed` | counter | Received packets missed (true missed field from ip -s link) |
| `network_interface_stats_rx_multicast` | counter | Received multicast packets |
| `network_interface_stats_tx_bytes` | counter | Transmitted bytes |
| `network_interface_stats_tx_packets` | counter | Transmitted packets |
| `network_interface_stats_tx_errors` | counter | Transmission errors |
| `network_interface_stats_tx_dropped` | counter | Transmitted packets dropped |
| `network_interface_stats_tx_carrier` | counter | Carrier errors |
| `network_interface_stats_tx_collisions` | counter | Collision errors |

### Labels

Each metric includes the following labels:
- `cluster`: AKS cluster identifier
- `environment`: Environment tag (configurable)
- `host`: Node hostname
- `hostname`: Node hostname (duplicate for compatibility)
- `interface`: Network interface name (eth0, eth1, etc.)
- `state`: Interface operational state

### Customization

#### Modify Collection Interval

Edit the `telegraf.conf` section in the ConfigMap:
```yaml
[agent]
  interval = "15s"  # Change from 30s to 15s
  flush_interval = "15s"
```

#### Change Global Tags

Update the global tags section:
```yaml
[global_tags]
  environment = "production"  # Change environment
  cluster = "my-cluster"      # Change cluster name
  region = "eastus"           # Add custom tags
```

#### Add Additional Metrics

Modify the parsing script `parse_ip_stats.sh` to extract additional fields from `/proc/net/dev`.

## Prometheus Integration

### PodMonitor Configuration

The included PodMonitor automatically configures Azure Managed Prometheus to scrape metrics:

```yaml
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: telegraf-podmonitor
spec:
  selector:
    matchLabels:
      app: telegraf
  podMetricsEndpoints:
  - port: prometheus
    interval: 30s
    path: /metrics
```

### Key Differences from OSS Prometheus

When using Azure Managed Prometheus, note the API version:
- **Azure Managed**: `azmonitoring.coreos.com/v1`
- **Open Source**: `monitoring.coreos.com/v1`

## Grafana Dashboards

### Sample PromQL Queries

```promql
# Network throughput rate by node
sum(rate(network_interface_stats_rx_bytes{interface="eth0"}[5m])) by (host)

# Network errors across the cluster
sum(rate(network_interface_stats_rx_errors[5m])) by (interface, host)

# Interface utilization percentage (if you know the link speed)
(rate(network_interface_stats_tx_bytes{interface="eth0"}[5m]) * 8) / (1000000000) * 100

# Top talkers by transmitted bytes
topk(10, network_interface_stats_tx_bytes)

# Top 5 interfaces with most missed packets
topk(5, network_interface_stats_rx_missed)

# Top 5 interfaces with highest missed packet rate
topk(5, rate(network_interface_stats_rx_missed[5m]))

# Top 5 interfaces by missed packet percentage
topk(5, 
  (
    rate(network_interface_stats_rx_missed[5m]) / 
    rate(network_interface_stats_rx_packets[5m])
  ) * 100
)
```

### Table Visualizations in Grafana

For **current state tables** (like "Top 5" reports), use these configuration settings:

**Query Configuration:**
- **Query Type**: Set to **Instant** (not Range)
- **Query**: Use queries without rate functions for current values
  ```promql
  # Current missed packets (for tables) - use max by to deduplicate
  topk(5, max by (host, interface) (network_interface_stats_rx_missed))
  
  # Current error counts (for tables)  
  topk(10, max by (host, interface) (network_interface_stats_rx_errors))
  ```

**Panel Configuration:**
- **Visualization**: Table
- **Query Type**: **Instant** ← Important! This prevents duplicate rows
- **Format**: Table
- **Transform**: No additional transforms needed

**Why Instant vs Range:**
- **Range queries**: Return time-series data over a window → Multiple rows per metric
- **Instant queries**: Return current value only → One row per metric
- For tables showing current state, always use **Instant** queries

### CoreDNS Monitoring

This solution can be extended to monitor CoreDNS metrics alongside network interface statistics:

#### Prerequisites for CoreDNS Monitoring

1. **ServiceMonitor**: Create a ServiceMonitor to scrape CoreDNS metrics
2. **Metrics Port**: Ensure CoreDNS service exposes the metrics port (9153)

#### Setup CoreDNS Monitoring

```bash
# Add metrics port to CoreDNS service
kubectl patch svc kube-dns -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "metrics", "port": 9153, "protocol": "TCP", "targetPort": 9153}}]'

# Create ServiceMonitor
cat <<EOF> corednsMetrics.yaml
apiVersion: azmonitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: coredns-servicemonitor
  namespace: kube-system
  labels:
    app: coredns
spec:
  selector:
    matchLabels:
      k8s-app: kube-dns
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
    scheme: http
EOF
```

Apply it:

```bash
kubectl apply -f corednsMetrics.yaml
```

#### CoreDNS PromQL Queries

```promql
# DNS request rate by type
rate(coredns_dns_requests_total[5m])

# DNS response codes
rate(coredns_dns_responses_total[5m])

# DNS request duration (95th percentile)
histogram_quantile(0.95, rate(coredns_dns_request_duration_seconds_bucket[5m]))

# DNS cache hit ratio
rate(coredns_cache_hits_total[5m]) / rate(coredns_cache_requests_total[5m])

# Forward requests
rate(coredns_forward_requests_total[5m])

# DNS response size
coredns_dns_response_size_bytes_count
```

### Time-Series vs Table Queries

| Visualization Type | Query Type | Example Query | Use Case |
|-------------------|------------|---------------|----------|
| **Graph/Chart** | Range | `rate(network_interface_stats_rx_missed[5m])` | Trends over time |
| **Table** | Instant | `topk(5, max by (host, interface) (network_interface_stats_rx_missed))` | Current top values |
| **Single Stat** | Instant | `sum(network_interface_stats_rx_errors)` | Current total |

### Creating Custom Dashboards

1. **Navigate** to Azure Managed Grafana
2. **Create** a new dashboard
3. **Add visualization** with Managed Prometheus data source
4. **Use** the PromQL queries above as starting points

Reference: [Creating Grafana Dashboards Guide](https://dcasati.github.io/aks-labs/docs/operations/observability-and-monitoring#create-a-dashboard-in-grafana-to-visualize-the-new-metric)

## Troubleshooting

### Check DaemonSet Status
```bash
kubectl describe daemonset telegraf
kubectl get pods -l app=telegraf -o wide
```

### Check Pod Logs
```bash
kubectl logs -l app=telegraf --tail=50 -f
```

### Verify Metrics Endpoint
```bash
# Port-forward to a pod
kubectl port-forward pod/<telegraf-pod-name> 2112:2112

# Test endpoint
curl http://localhost:2112/metrics
```

### Check PodMonitor
```bash
kubectl get podmonitor telegraf-podmonitor -o yaml
kubectl describe podmonitor telegraf-podmonitor
```

### Test Script Manually
```bash
# Connect to a pod
kubectl exec -it <telegraf-pod-name> -- sh

# Run the parsing script manually
/usr/local/bin/parse_ip_stats.sh

# Check Telegraf configuration
telegraf --config /etc/telegraf/telegraf.conf --test
```

### Common Issues

1. **No metrics in Prometheus**: 
   - Check if PodMonitor is using correct API version (`azmonitoring.coreos.com/v1`)
   - Verify pod labels match PodMonitor selector

2. **Permission denied errors**: 
   - Ensure DaemonSet has `privileged: true` and `hostNetwork: true`

3. **Missing interfaces**: 
   - Check if parsing script filters out certain interfaces
   - Verify `/proc/net/dev` is accessible in container

4. **High memory usage**:
   - Adjust resource limits in DaemonSet spec
   - Increase `flush_interval` to batch more data

## Performance and Scaling

### Resource Usage
- **CPU**: ~100m per pod (200m limit)
- **Memory**: ~64Mi per pod (128Mi limit)
- **Network**: Minimal impact, only exposes metrics endpoint

### Scaling Considerations
- Automatically scales with cluster (one pod per node)
- Metrics volume scales with number of network interfaces per node
- Consider metric retention policies in Azure Monitor

## Security Considerations

- **Privileged access**: Required to read host network statistics
- **Host network**: Needed to access accurate network interface data
- **RBAC**: Service account has minimal required permissions
- **Resource limits**: Prevents resource exhaustion

## Key Benefits

- **Standard tooling**: Uses cloud-native monitoring patterns
- **Native integration**: Built for Kubernetes and Azure environments
- **Powerful querying**: PromQL provides flexible time-series analysis
- **Cost efficient**: Uses Azure managed services
- **Operational simplicity**: Minimal infrastructure to maintain
- **Comprehensive monitoring**: Covers both network interfaces and DNS metrics

## References

- [AKS Labs - Advanced Observability](https://dcasati.github.io/aks-labs/docs/operations/observability-and-monitoring)
- [Azure Managed Prometheus Documentation](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-scrape-crd)
- [Telegraf Prometheus Output Plugin](https://github.com/influxdata/telegraf/blob/release-1.28/plugins/outputs/prometheus_client/README.md)
- [Prometheus Monitoring with Azure Monitor](https://www.youtube.com/watch?v=Dc0TqbAkQX0)

## Contributing

To modify or extend this solution:

1. Update the Telegraf configuration in the ConfigMap
2. Modify the parsing script for additional metrics
3. Adjust resource limits based on your cluster size
4. Customize labels and tags for your environment

---

**Note**: This solution provides a foundation for network monitoring in AKS. Extend it based on your specific observability requirements.
