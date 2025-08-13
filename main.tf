# Creating the Target Group
#------------------------------------------------------
resource "aws_lb_target_group" "component" {
  name     = "${local.name}-${var.tags.Component}"
  port     = 8080
  protocol = "HTTP"
#   vpc_id   = data.aws_ssm_parameter.vpc_id.value
  vpc_id   = var.vpc_id
  deregistration_delay = 60
  health_check {
    healthy_threshold     = 2
    interval              = 10 
    unhealthy_threshold   = 3
    timeout               = 5
    path                  = "/health"
    port                  = 8080
    matcher               = "200-299"
  }
}

# Creating the Catalogue AMI
#------------------------------------------------------
module "component" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  ami = data.aws_ami.rhel-9.id
  name = "${local.name}-${var.tags.Component}-ami"

  instance_type = "t2.micro"
#   vpc_security_group_ids = [data.aws_ssm_parameter.catalogue_sg_id.value]
  vpc_security_group_ids = [var.component_sg_id]
  #subnet_id     = element(split(",", data.aws_ssm_parameter.private_subnet_ids.value), 0)
  subnet_id     = var.private_subnet_id # We are splitting the private subnets from parameter store and taking one subnet using element function
  iam_instance_profile = var.iam_instance_profile
  create_security_group = false

  tags = merge(var.common_tags, var.tags)

}

# Provisioning the Component AMI with Catalogue data using ansible and bootstrap,sh
#------------------------------------------------------------------------------------
resource "null_resource" "component" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    instance_id = module.component.id 
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host = module.component.private_ip
    type = "ssh"
    user = "ec2-user"
    password = "DevOps321"
  }

  provisioner "file" {
    source = "bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "remote-exec" {
    # Bootstrap script called with private_ip of each node in the cluster
    inline = [
      "chmod +x /tmp/bootstrap.sh",
      "sudo sh /tmp/bootstrap.sh ${var.tags.Component} ${var.environment} ${var.app_version}"# We are parsing the variables as $1 (mongodb) and $2 (dev) to bootstrap script
    ]
  }
}

# Stopping the component AMI Instnace
#------------------------------------------------------
resource "aws_ec2_instance_state" "stop_component_instance" {
      instance_id = module.component.id
      state       = "stopped"
      depends_on = [ null_resource.component ]
}

# Taking the AMI from component AMI Instance
#------------------------------------------------------
resource "aws_ami_from_instance" "component" {
      name        = "${local.name}-${var.tags.Component}-${local.current_time}"
      source_instance_id = module.component.id
      depends_on = [ aws_ec2_instance_state.stop_component_instance ] # I've made changes here (added this)
  tags = {
    Name = "${var.tags.Component}-ami"
  }
}

# Deleting the Component AMI Instance
#------------------------------------------------------
resource "null_resource" "component_delete" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    # instance_id = aws_ami_from_instance.catalogue.id # It will trigger whenever the ami Id is changed which means new AMi created tis is conflicting 
    instance_id = module.component.id # It will trgger when catalogue instance id change 
  }

  provisioner "local-exec" {
    # Bootstrap script called with private_ip of each node in the cluster
    command = "aws ec2 terminate-instances --instance-ids ${module.component.id}"
  }
  depends_on = [ aws_ami_from_instance.component ]
}


# Creating the Launch Template using AMI we just created
#------------------------------------------------------
resource "aws_launch_template" "component" {
  name = "${local.name}-${var.tags.Component}"

  image_id = aws_ami_from_instance.component.id 

  instance_initiated_shutdown_behavior = "terminate"


  instance_type = "t2.micro"
  update_default_version = true


  #vpc_security_group_ids = [data.aws_ssm_parameter.catalogue_sg_id.value]
  vpc_security_group_ids = [var.component_sg_id]

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name}-${var.tags.Component}"
    }
  }
}

# Creating Autoscaling group
#------------------------------------------------------

resource "aws_autoscaling_group" "component" {
  name                      = "${local.name}-${var.tags.Component}"
  max_size                  = 10
  min_size                  = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  desired_capacity          = 2
  #vpc_zone_identifier       = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.component.arn]
  
  launch_template {
    id      = aws_launch_template.component.id
    version = aws_launch_template.component.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"]
  }

  timeouts {
    delete = "15m"
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-${var.tags.Component}"
    propagate_at_launch = true
  }

}

# Create aws load balancer rule 
#---------------------------------------------------------------------------------
resource "aws_lb_listener_rule" "component" {
  #listener_arn = data.aws_ssm_parameter.app_alb_listener_arn.value
  listener_arn = var.app_alb_listener_arn
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.component.arn
  }

  condition {
    host_header {
      values = ["${var.tags.Component}.app-${var.environment}.${var.zone_name}"] # catalogue.app-dev.devopsprocloud.in
    }
  }

}

# Create Autoscale Group Policy
#---------------------------------------------------------------------------------
resource "aws_autoscaling_policy" "component" {
  autoscaling_group_name = aws_autoscaling_group.component.name 
  name                   = "${local.name}-${var.tags.Component}"
  policy_type            = "TargetTrackingScaling"
 
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0 # if CPU usage increases more than 2% the new instance will be created by launchpad
  }
}