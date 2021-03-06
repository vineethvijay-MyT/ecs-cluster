# Specify the provider and access details
provider "aws" {
  region = "${var.aws_region}"
}

### NETWORK CONFIGURATIONS ###

# Fetch AZs in the current region
data "aws_availability_zones" "available" {}

# Create VPC with support for service discovery
resource "aws_vpc" "main" {
  cidr_block = "10.16.0.0/16"
  enable_dns_support = "true"
  enable_dns_hostnames = "true"
}

# Create var.az_count private subnets, each in a different AZ
#cidrsubnet(iprange, newbits, netnum)
resource "aws_subnet" "private" {
  count             = "${var.az_count}"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id            = "${aws_vpc.main.id}"
}

# Create var.az_count public subnets, each in a different AZ
resource "aws_subnet" "public" {
  count                   = "${var.az_count}"
  cidr_block              = "${cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count + count.index)}"
  availability_zone       = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id                  = "${aws_vpc.main.id}"
  map_public_ip_on_launch = true
}


# Create Internet Gatway for the public subnet
resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"
}

# Route the public subnet traffic through the IGW
resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.main.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.gw.id}"
}

# Create a NAT gateway with an EIP for each private subnet to get internet connectivity
resource "aws_eip" "gw" {
  count      = "${var.az_count}"
  vpc        = true
  depends_on = ["aws_internet_gateway.gw"]
}

resource "aws_nat_gateway" "gw" {
  count         = "${var.az_count}"
  subnet_id     = "${element(aws_subnet.public.*.id, count.index)}"
  allocation_id = "${element(aws_eip.gw.*.id, count.index)}"
}

# Create a new route table for the private subnets
# And make it route non-local traffic through the NAT gateway to the internet
resource "aws_route_table" "private" {
  count  = "${var.az_count}"
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${element(aws_nat_gateway.gw.*.id, count.index)}"
  }
}

# Explicitely associate the newly created route tables to the private subnets (so they don't default to the main route table)
resource "aws_route_table_association" "private" {
  count          = "${var.az_count}"
  subnet_id      = "${element(aws_subnet.private.*.id, count.index)}"
  route_table_id = "${element(aws_route_table.private.*.id, count.index)}"
}

# Route53 Service Discovery
resource "aws_service_discovery_private_dns_namespace" "ecs_private_ns" {
  name        = "hoge.example.local"
  description = "Service Discovery"
  vpc         = "${aws_vpc.main.id}"
}

resource "aws_service_discovery_service" "example" {
  name = "example"
  dns_config {
    namespace_id = "${aws_service_discovery_private_dns_namespace.ecs_private_ns.id}"
    dns_records {
      ttl = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

### SECURITY ###

#IAM
resource "aws_iam_role" "ecs_execution_role" {
  name = "tf_ecs_execution_role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ecs_execution_policy" {
  name = "ecs_execution_policy"
  role = "${aws_iam_role.ecs_execution_role.name}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets",
        "ecr:GetAuthorizationToken",
			  "ecr:BatchCheckLayerAvailability",
			  "ecr:GetDownloadUrlForLayer",
			  "ecr:GetRepositoryPolicy",
			  "ecr:DescribeRepositories",
			  "ecr:ListImages",
			  "ecr:DescribeImages",
			  "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}




# ALB Security group
# This is the group to edit if  want to restrict access to application
resource "aws_security_group" "lb" {
  name        = "tf-ecs-alb-sg"
  description = "Controls access to the ALB"
  vpc_id      = "${aws_vpc.main.id}"

  ingress = [
    {
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Traffic to the ECS Cluster should only come from the ALB
resource "aws_security_group" "ecs_web_sg" {
  name        = "tf-ecs-web-sg"
  description = "Allow inbound access from the ALB only"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    protocol        = "tcp"
    from_port       = "${var.web_port}"
    to_port         = "${var.web_port}"
    security_groups = ["${aws_security_group.lb.id}"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_app_sg" {
  name        = "tf-ecs-app-sg"
  description = "Allow inbound access from the Web only"
  vpc_id      = "${aws_vpc.main.id}"

  ingress =[
   {
    protocol        = "tcp"
    from_port       = "${var.app_port}"
    to_port         = "${var.app_port}"
    security_groups = ["${aws_security_group.ecs_web_sg.id}"]
   }
  ]

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### CERTIFICATES ###
#Creating a dummy SSL certificate
resource "tls_private_key" "example" {
  algorithm = "RSA"
}

resource "tls_self_signed_cert" "example" {
  key_algorithm   = "RSA"
  private_key_pem      = "${tls_private_key.example.private_key_pem}"
  subject {
    common_name  = "example.com"
    organization = "Smava Examples, Inc"
  }

  validity_period_hours = 336

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "cert_signing",
  ]
}

resource "aws_iam_server_certificate" "test_cert" {
  name = "terraform-test-cert"
  certificate_body = "${tls_self_signed_cert.example.cert_pem}"
  private_key      = "${tls_private_key.example.private_key_pem}"
}

### LOAD BALANCERS ###

#Creating the front end Application Load Balancer
resource "aws_alb" "main" {
  name            = "tf-ecs-task-alb"
  subnets         = ["${aws_subnet.public.*.id}"]
  security_groups = ["${aws_security_group.lb.id}"]
}

resource "aws_alb_target_group" "web" {
  name        = "tf-ecs-task-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = "${aws_vpc.main.id}"
  target_type = "ip"
}

# Redirect all traffic on ALB to the target group
resource "aws_alb_listener" "http" {
  load_balancer_arn = "${aws_alb.main.id}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.web.id}"
    type             = "forward"
  }
}

resource "aws_alb_listener" "https" {
  load_balancer_arn = "${aws_alb.main.id}"
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2015-05"
  certificate_arn   = "${aws_iam_server_certificate.test_cert.arn}"


  default_action {
    target_group_arn = "${aws_alb_target_group.web.id}"
    type             = "forward"
  }
}

### CONTAINERS ###
resource "aws_ecs_cluster" "main" {
  name = "tf-ecs-cluster"
}

#Container definitions for appserver and webserver
data "template_file" "app_task_definition" {
  template = "${file("${path.module}/appserver/task-definition.json")}"

  vars {
    app_image_url        = "496391058917.dkr.ecr.eu-central-1.amazonaws.com/helloworld"
    app_container_name   = "helloworld"
    log_group            = "${aws_cloudwatch_log_group.app.name}"
    region               = "${var.aws_region}"
  }
}
data "template_file" "web_task_definition" {
  template = "${file("${path.module}/webserver/task-definition.json")}"

  vars {
    web_image_url        = "496391058917.dkr.ecr.eu-central-1.amazonaws.com/webserver"
    web_container_name   = "webserver"
    log_group            = "${aws_cloudwatch_log_group.web.name}"
    region               = "${var.aws_region}"
  }
}


resource "aws_ecs_task_definition" "web" {
  family                   = "web"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "${var.web_fargate_cpu}"
  memory                   = "${var.web_fargate_memory}"
  container_definitions    = "${data.template_file.web_task_definition.rendered}"
  execution_role_arn       = "${aws_iam_role.ecs_execution_role.arn}"
  

}

resource "aws_ecs_task_definition" "app" {
  family                   = "app" 
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "${var.app_fargate_cpu}"
  memory                   = "${var.app_fargate_memory}"
  container_definitions    = "${data.template_file.app_task_definition.rendered}"
  execution_role_arn       = "${aws_iam_role.ecs_execution_role.arn}"
}

resource "aws_ecs_service" "web" {
  name            = "tf-ecs-web-service"
  cluster         = "${aws_ecs_cluster.main.id}"
  task_definition = "${aws_ecs_task_definition.web.arn}"
  desired_count   = "${var.web_count}"
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = ["${aws_security_group.ecs_web_sg.id}"]
    subnets         = ["${aws_subnet.private.*.id}"]
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.web.id}"
    container_name   = "webserver"
    container_port   = "${var.web_port}"
  }

  depends_on = [
    "aws_alb_listener.http",
    "aws_iam_role_policy.ecs_execution_policy"
  ]
}


resource "aws_ecs_service" "app" {
  name            = "tf-ecs-app-service"
  cluster         = "${aws_ecs_cluster.main.id}"
  task_definition = "${aws_ecs_task_definition.app.arn}"
  desired_count   = "${var.app_count}"
  launch_type     = "FARGATE"

#  network_configuration {
#    security_groups = ["${aws_security_group.ecs_app_sg.id}"]
#    subnets         = ["${aws_subnet.private.*.id}"]
#  }

  network_configuration {
    security_groups  = ["${aws_security_group.ecs_app_sg.id}"]
    subnets          = ["${aws_subnet.public.*.id}"]
    assign_public_ip = "true"
  }

  service_registries {
    registry_arn = "${aws_service_discovery_service.example.arn}"
  }

    depends_on = [
    "aws_iam_role_policy.ecs_execution_policy"
  ]
}

### LOGGING ###
#Cloudwatch Log Group
resource "aws_cloudwatch_log_group" "web" {
  name = "webserver"

  tags {
    Application = "webserver"
    
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name = "appserver"

  tags {
    Application = "appserver"
    
  }
}

### SCALING ###
# A CloudWatch alarm that monitors memory utilization of containers for scaling up
#https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html
resource "aws_cloudwatch_metric_alarm" "appserver_memory_high" {
  alarm_name = "appserver-memory-utilization-above-80"
  alarm_description = "This alarm monitors appserver memory utilization for scaling up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name = "MemoryUtilization"
  namespace = "AWS/ECS"
  evaluation_periods = "1"
  period = "120"
  statistic = "Average"
  threshold = "80"
  alarm_actions = ["${aws_appautoscaling_policy.app_scale_up.arn}"]

  dimensions {
    ClusterName = "${aws_ecs_cluster.main.name}"
    ServiceName = "${aws_ecs_service.app.name}"
  }
}

# A CloudWatch alarm that monitors memory utilization of containers for scaling down
resource "aws_cloudwatch_metric_alarm" "appserver_memory_low" {
  alarm_name = "appserver-memory-utilization-below-5"
  alarm_description = "This alarm monitors appserver memory utilization for scaling down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods = "1"
  metric_name = "MemoryUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "5"
  alarm_actions = ["${aws_appautoscaling_policy.app_scale_down.arn}"]

  dimensions {
    ClusterName = "${aws_ecs_cluster.main.name}"
    ServiceName = "${aws_ecs_service.app.name}"
  }
}

resource "aws_appautoscaling_target" "target" {
  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  role_arn = "${aws_iam_role.ecs_execution_role.arn}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
  min_capacity = "${var.app_min_capacity}"
  max_capacity = "${var.app_max_capacity}"
}
#https://www.terraform.io/docs/providers/aws/r/appautoscaling_policy.html
resource "aws_appautoscaling_policy" "app_scale_up" {
  name = "appserver-scale-up"
  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }

  depends_on = ["aws_appautoscaling_target.target"]
}

resource "aws_appautoscaling_policy" "app_scale_down" {
  name = "appserver-scale-down"
  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
  depends_on = ["aws_appautoscaling_target.target"]
}
#test change
