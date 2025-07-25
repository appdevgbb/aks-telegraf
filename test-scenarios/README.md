# Test Scenarios for Network Monitoring

This directory contains various test scenarios to validate the Telegraf network monitoring solution and demonstrate its capabilities under different load conditions.

## Test Environment

### Load Testing Machine
- **VM**: Standard F2s v2 (2 vcpus, 4 GiB memory)
- **Network**: Same VNet as AKS cluster
- **Purpose**: Generate high-volume HTTP traffic using wrk

### AKS Cluster
- **Target Service**: Running on `10.224.0.14:8080`
- **Node Labeling**: Custom labels for pod co-scheduling
- **Workloads**: Mix of web services and blob upload pods

## Test Scenarios

### 1. High-Volume HTTP Load Test

**Objective**: Generate significant network traffic to test interface monitoring under load.

**Load Generator Configuration**:
```bash
# Increase file descriptor limit
ulimit -n 65535

# Run wrk with high concurrency
wrk -t24 -c4000 -d120s -s random-path.lua http://10.224.0.14:8080
```

**Traffic Pattern** (`random-path.lua`):
```lua
-- Sends GET requests to /path?value=random
math.randomseed(os.time())

request = function()
  local val = math.random(1, 1000000)
  return string.format("GET /?v=%d HTTP/1.1\r\nHost: 4.236.46.39\r\n\r\n", val)
end
```

**Expected Metrics Impact**:
- **RX bytes/packets**: Significant increase on target node interfaces
- **TX bytes/packets**: High outbound traffic from web service pods
- **Connection tracking**: Monitor for any dropped packets under high concurrency

### 2. Large File Upload Test

**Objective**: Test network monitoring during sustained large data transfers.

**Test Configuration**:
- **File Size**: 10GB upload to Azure Blob Storage
- **Co-scheduling**: Upload pod scheduled with web service pod on labeled node
- **Duration**: Extended transfer time for sustained monitoring

**Expected Metrics Impact**:
- **TX bytes**: Sustained high outbound traffic to Azure Blob Storage
- **Interface utilization**: Monitor bandwidth utilization percentages
- **Errors**: Verify no packet loss during large transfers

### 3. Combined Load Test

**Objective**: Monitor network behavior under mixed workload conditions.

**Test Setup**:
- Simultaneous wrk load testing (4000 concurrent connections)
- 10GB blob upload in progress
- Multiple pods co-scheduled on same node

**Key Monitoring Points**:
1. **Interface saturation**: Watch for approaching bandwidth limits
2. **Packet loss**: Monitor `rx_missed` and `rx_dropped` fields
3. **Error rates**: Track `rx_errors` and `tx_errors` under stress
4. **Resource contention**: Compare performance across different node interfaces

## Monitoring Queries for Test Scenarios

### Real-time Traffic Monitoring

```promql
# Current network throughput by interface (last 5 minutes)
rate(network_interface_stats_rx_bytes{interface="eth0"}[5m]) * 8 / 1000000

# TX traffic rate in Mbps
rate(network_interface_stats_tx_bytes{interface="eth0"}[5m]) * 8 / 1000000

# Combined RX+TX traffic
(rate(network_interface_stats_rx_bytes{interface="eth0"}[5m]) + rate(network_interface_stats_tx_bytes{interface="eth0"}[5m])) * 8 / 1000000
```

### Packet Loss Detection

```promql
# Missed packet rate (packets/sec)
rate(network_interface_stats_rx_missed[5m])

# Missed packet percentage
(rate(network_interface_stats_rx_missed[5m]) / rate(network_interface_stats_rx_packets[5m])) * 100

# Dropped packet rate
rate(network_interface_stats_rx_dropped[5m])
```

### Error Monitoring

```promql
# Network errors by interface
rate(network_interface_stats_rx_errors[5m])
rate(network_interface_stats_tx_errors[5m])

# Top interfaces with errors
topk(5, rate(network_interface_stats_rx_errors[5m]))
```

### Load Test Specific Metrics

```promql
# Identify high-traffic nodes during load test
topk(5, rate(network_interface_stats_rx_bytes{interface="eth0"}[1m]))

# Monitor specific node during blob upload
rate(network_interface_stats_tx_bytes{host="your-node-name",interface="eth0"}[5m]) * 8 / 1000000

# Compare traffic before/during/after test
rate(network_interface_stats_rx_bytes{interface="eth0"}[5m])[30m:1m]
```

## Expected Results

### During HTTP Load Test (wrk)
- **RX Traffic**: 400-800 Mbps depending on response sizes
- **Connection Rate**: High packet-per-second rates
- **Latency Impact**: Minimal if network interface handles load well

### During Blob Upload
- **TX Traffic**: Sustained 100-500 Mbps outbound
- **Duration**: 2-5 minutes for 10GB depending on bandwidth
- **Pattern**: Consistent throughput vs. bursty HTTP traffic

### Combined Load
- **Total Utilization**: Sum of both patterns
- **Resource Contention**: Potential impact on response times
- **Monitoring Value**: Demonstrates real-world mixed workload scenarios

## Alerting Thresholds

Based on test results, consider setting alerts for:

```promql
# High packet loss (>0.1%)
(rate(network_interface_stats_rx_missed[5m]) / rate(network_interface_stats_rx_packets[5m])) * 100 > 0.1

# High error rate (>10 errors/sec)
rate(network_interface_stats_rx_errors[5m]) > 10

# Interface utilization (>80% of 1Gbps)
rate(network_interface_stats_rx_bytes[5m]) * 8 > 800000000
```

## Node Setup for Co-scheduling

To run the test workloads on a specific node for better monitoring, label a node first:

```bash
# 1. List available nodes
kubectl get nodes

# 2. Label your chosen node for dedicated workloads
kubectl label node aks-armnp-38629262-vmss000000 dedicated=web-arm

# 3. Verify the label was applied
kubectl get node aks-armnp-38629262-vmss000000 --show-labels | grep dedicated
```

The test pods are configured with `nodeSelector: dedicated: web-arm` to ensure they run on your labeled node.

## Files in This Directory

- `wrk-load-test.sh` - Script to run wrk load test
- `random-path.lua` - Lua script for wrk with random paths
- `blob-upload-test.yaml` - Kubernetes pod for blob upload test
- `pod-web.yaml` - Web service pod for load testing target

## Running the Tests

1. **Setup**: Deploy Telegraf monitoring first
2. **Node Labeling**: Label a node using the command above
3. **Deploy Test Pods**: Apply the web service and blob upload pods
4. **Baseline**: Capture baseline metrics for 5 minutes
5. **Load Test**: Run wrk for 2 minutes, monitor in real-time
6. **Blob Upload**: Start 10GB upload, monitor sustained traffic
7. **Combined**: Run both simultaneously
8. **Analysis**: Compare metrics across all scenarios

This comprehensive testing validates the monitoring solution under realistic high-load conditions and demonstrates its value for production workloads.
