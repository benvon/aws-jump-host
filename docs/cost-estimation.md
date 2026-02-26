# Cost Estimation Guide

## Purpose

This guide provides a practical framework to estimate monthly cost for this jump host platform and a worked example using:

- 1 x `t4g.micro`
- 3 developers
- daily usage during working hours over SSM

## Key Point About SSM Cost

For Amazon EC2 targets, **Session Manager interactive access has no additional charge**. In most deployments, the larger cost drivers are:

- endpoint/network fixed cost (for private connectivity)
- EC2 uptime and size
- EBS storage
- CloudWatch log ingestion/storage

## Estimation Framework

Estimate monthly cost as:

`Total = EC2 + EBS + EndpointHourly + EndpointData + CloudWatchLogs + OptionalFeatures`

### 1) EC2

`EC2 = instance_hour_rate * instance_hours_per_month`

### 2) EBS (root + home volume)

`EBS = (root_gb + home_gb) * gp3_rate_per_gb_month`

If you provision extra gp3 IOPS/throughput beyond baseline, add those charges.

### 3) Interface Endpoint Hourly (PrivateLink)

`EndpointHourly = endpoint_count * hourly_rate_per_endpoint * endpoint_hours_per_month`

For this platform, typical endpoint count is 4 (`ssm`, `ssmmessages`, `ec2messages`, `logs`), plus optional `kms`.

### 4) Interface Endpoint Data Processing

`EndpointData = endpoint_data_gb * data_processing_rate_per_gb`

### 5) CloudWatch Logs

`CloudWatchLogs = (ingested_gb * ingest_rate_per_gb) + (stored_gb * storage_rate_per_gb_month)`

### 6) Optional Features

- Systems Manager Just-in-time node access (if enabled): per-node-hour.
- KMS request charges (usually small, usage-dependent).
- NAT Gateway (if used instead of private endpoints).

## Input Worksheet (Copy to Spreadsheet)

- Region
- Instance type
- Instance hour rate
- Instance hours/month
- Root volume GB
- Home volume GB
- gp3 $/GB-month
- Number of interface endpoints
- Endpoint hours/month
- Endpoint $/hour
- Endpoint data GB/month
- Endpoint $/GB
- CloudWatch logs ingested GB/month
- CloudWatch ingest $/GB
- CloudWatch logs stored GB-month
- CloudWatch storage $/GB-month
- JIT node access enabled? (yes/no)
- JIT node-hours/month
- JIT $/node-hour

## Worked Example: `t4g.micro`, 3 Devs, Daily Working Hours

Assumptions for illustration:

- Region: `us-east-1`
- 3 developers, each 8 hours/day, 22 days/month
- Active session hours total: `3 * 8 * 22 = 528 session-hours/month`
- Instance: `t4g.micro` at `$0.0084/hour`
- Instance runs business hours only: `176 hours/month` (8h * 22d)
- EBS: root `20 GB` + home `20 GB` (module defaults) = `40 GB`
- gp3 storage rate: `$0.08/GB-month`
- Interface endpoints: `4` endpoints, one AZ, `730 h/month`, `$0.01/hour`
- Endpoint data processing: `15 GB/month` at `$0.01/GB`
- CloudWatch logs ingestion: `1.81 GB/month` (assuming average 1 KB/sec across active sessions)
- CloudWatch logs storage: `1.81 GB-month`
- CloudWatch rates used: `$0.50/GB` ingest, `$0.03/GB-month` storage
- JIT node access disabled

### Example Calculation

- `EC2 = 176 * 0.0084 = $1.48`
- `EBS = 40 * 0.08 = $3.20`
- `EndpointHourly = 4 * 730 * 0.01 = $29.20`
- `EndpointData = 15 * 0.01 = $0.15`
- `CloudWatch ingest = 1.81 * 0.50 = $0.91`
- `CloudWatch storage = 1.81 * 0.03 = $0.05`

Estimated monthly total:

- **`$34.99/month`**

### Same Example if Instance Runs 24x7

Only EC2 changes:

- `EC2 = 730 * 0.0084 = $6.13`

Revised total:

- **`$39.64/month`**

## Interpretation

In this profile, SSM session usage itself is not the major cost component; fixed private connectivity (interface endpoint hourly cost) is usually larger.

## Cost-Control Levers

1. Stop/start hosts outside work hours.
2. Minimize endpoint footprint (AZ count and optional endpoints).
3. Tune CloudWatch retention and reduce noisy shell output.
4. Keep to right-sized burstable instances.
5. Avoid enabling billable optional SSM features unless needed (for example JIT node access).

## Pricing Sources (Verify for Your Region)

- AWS Systems Manager pricing: https://aws.amazon.com/systems-manager/pricing/
- AWS PrivateLink pricing: https://aws.amazon.com/privatelink/pricing/
- Amazon CloudWatch pricing: https://aws.amazon.com/cloudwatch/pricing/
- Amazon EBS pricing: https://aws.amazon.com/ebs/pricing/
- AWS docs example showing `t4g.micro` `$0.0084/hour`: https://docs.aws.amazon.com/solutions/latest/data-transfer-hub/cost.html
