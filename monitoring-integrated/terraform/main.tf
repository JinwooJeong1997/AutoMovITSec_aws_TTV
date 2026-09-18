data "aws_subnet" "selected" { id = var.subnet_id }
data "aws_sqs_queue" "logs" { name = var.queue_name }
data "aws_ami" "ubuntu" {
  most_recent = true
  owners = ["099720109477"]
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
}
locals {
  # 배포 파일을 명시적으로 선택한다. secrets, .env, data는 패키지에 포함하지 않는다.
  runtime_files = concat(
    ["compose.yaml", "gateway/default.conf", "loki/config.yaml"],
    [for f in fileset("${path.module}/../runtime/agent", "*.py") : "agent/${f}"],
    ["agent/index.html", "agent/Dockerfile", "agent/requirements.txt"],
    ["worker/worker.py", "worker/Dockerfile", "worker/requirements.txt"],
    ["demo/demo.py", "demo/Dockerfile", "demo/requirements.txt"],
    ["grafana/provisioning/datasources/loki.yaml", "grafana/provisioning/dashboards/default.yaml", "grafana/dashboards/overview.json"]
  )
}
data "archive_file" "bundle" {
  type = "zip"
  output_path = "${path.module}/deployment.zip"
  dynamic "source" {
    for_each = toset(local.runtime_files)
    content {
      content = file("${path.module}/../runtime/${source.value}")
      filename = "runtime/${source.value}"
    }
  }
  source {
    content = file("${path.module}/../scripts/init_local.py")
    filename = "scripts/init_local.py"
  }
}
resource "aws_s3_bucket" "artifact" {
  bucket_prefix = "${var.name}-"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "artifact" {
  bucket = aws_s3_bucket.artifact.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "artifact" {
  bucket = aws_s3_bucket.artifact.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_object" "bundle" {
  bucket = aws_s3_bucket.artifact.id
  key = "releases/${data.archive_file.bundle.output_sha256}.zip"
  source = data.archive_file.bundle.output_path
  source_hash = data.archive_file.bundle.output_sha256
  server_side_encryption = "AES256"
  depends_on = [aws_s3_bucket_public_access_block.artifact]
}
resource "aws_security_group" "monitor" {
  name_prefix = "${var.name}-"
  vpc_id = var.vpc_id
  ingress {
    protocol = "tcp"
    from_port = 22
    to_port = 22
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    protocol = "-1"
    from_port = 0
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "monitor" {
  name_prefix = "${var.name}-"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "monitor" {
  role = aws_iam_role.monitor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = data.aws_sqs_queue.logs.arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = aws_s3_object.bundle.arn }
    ], var.sqs_kms_key_arn == null ? [] : [
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.sqs_kms_key_arn }
    ], var.enable_cloudwatch_datasource ? [
      { Effect = "Allow", Action = ["cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "ec2:DescribeInstances", "ec2:DescribeRegions", "ec2:DescribeTags", "tag:GetResources"], Resource = "*" }
    ] : [], length(var.bedrock_resource_arns) == 0 ? [] : [
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = var.bedrock_resource_arns }
    ])
  })
}
resource "aws_iam_instance_profile" "monitor" {
  name_prefix = "${var.name}-"
  role = aws_iam_role.monitor.name
}
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size = var.data_disk_gb
  type = "gp3"
  encrypted = true
  tags = { Name = "${var.name}-data" }
  lifecycle { prevent_destroy = true }
}
resource "aws_instance" "monitor" {
  ami = coalesce(var.ami_id, data.aws_ami.ubuntu.id)
  instance_type = var.instance_type
  subnet_id = var.subnet_id
  vpc_security_group_ids = [aws_security_group.monitor.id]
  associate_public_ip_address = true
  key_name = var.key_name
  iam_instance_profile = aws_iam_instance_profile.monitor.name
  metadata_options {
    http_endpoint = "enabled"
    http_tokens = "required"
    # Docker bridge 내부의 Worker·Agent가 IAM 역할 자격증명을 읽도록 2로 설정한다.
    http_put_response_hop_limit = 2
  }
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted = true
  }
  credit_specification { cpu_credits = "standard" }
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    bucket = aws_s3_bucket.artifact.id
    datasource_b64 = base64encode(yamlencode({
      apiVersion = 1
      datasources = concat([
        { name = "Loki", uid = "loki", type = "loki", access = "proxy", url = "http://loki:3100", isDefault = true, editable = false }
      ], var.enable_cloudwatch_datasource ? [
        { name = "CloudWatch", uid = "cloudwatch", type = "cloudwatch", access = "proxy", editable = false, jsonData = { authType = "default", defaultRegion = var.aws_region } }
      ] : [])
    }))
    key = aws_s3_object.bundle.key
    volume_serial = replace(aws_ebs_volume.data.id, "-", "")
    runtime_env_b64 = base64encode(join("\n", [
      "AWS_REGION=${var.aws_region}",
      "QUEUE_URL=${data.aws_sqs_queue.logs.url}",
      "BEDROCK_MODEL_ID=${var.bedrock_model_id}",
      "DATA_ROOT=/srv/monitoring-data"
    ]))
  })
  tags = { Name = var.name }
  depends_on = [aws_iam_role_policy.monitor, aws_s3_object.bundle]
  lifecycle {
    precondition {
      condition = data.aws_subnet.selected.vpc_id == var.vpc_id
      error_message = "VPC와 서브넷이 일치하지 않습니다."
    }
    precondition {
      condition = var.bedrock_model_id == "" || length(var.bedrock_resource_arns) > 0
      error_message = "AI를 사용할 때 InvokeModel 대상 ARN도 지정하세요."
    }
  }
}
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id = aws_ebs_volume.data.id
  instance_id = aws_instance.monitor.id
  stop_instance_before_detaching = true
}
